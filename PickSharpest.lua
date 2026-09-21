local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local function shellQuote(value)
    local escaped = value:gsub("'", "'\\''")
    return "'" .. escaped .. "'"
end

-- Runs a shell command and returns its trimmed stdout, or nil if it failed
-- or produced nothing. Used to fall back to the login shell's PATH when a
-- tool isn't at one of the well-known install locations.
local function captureShellOutput(command)
    local temp = LrPathUtils.getStandardFilePath('temp')
    local outputPath = LrPathUtils.child(temp, 'wildlife-sharpness-detect.txt')
    local exitCode = LrTasks.execute(command .. ' > ' .. shellQuote(outputPath) .. ' 2>/dev/null')
    local output = (exitCode == 0 and LrFileUtils.exists(outputPath)) and LrFileUtils.readFile(outputPath) or nil
    local trimmed = output and output:match('^%s*(.-)%s*$') or nil
    return (trimmed and trimmed ~= '') and trimmed or nil
end

-- True if this Python binary can import the packages sharpness.py needs.
local function pythonHasDependencies(pythonPath)
    local command = shellQuote(pythonPath) .. ' -c "import numpy, PIL" > /dev/null 2>&1'
    return LrTasks.execute(command) == 0
end

-- Lightroom Classic (GUI-launched) doesn't inherit a shell's rc-file PATH,
-- so Homebrew/conda installs are often invisible to LrTasks.execute unless
-- addressed by absolute path. Try the well-known locations first, then fall
-- back to asking a login shell to resolve it the way a terminal would.
local function findPython()
    local home = LrPathUtils.getStandardFilePath('home')
    local candidates = {
        home .. '/miniforge3/envs/lightroom/bin/python3',
        home .. '/miniconda3/envs/lightroom/bin/python3',
        home .. '/anaconda3/envs/lightroom/bin/python3',
        home .. '/opt/miniconda3/envs/lightroom/bin/python3',
        '/opt/homebrew/Caskroom/miniforge/base/envs/lightroom/bin/python3',
        '/usr/local/Caskroom/miniforge/base/envs/lightroom/bin/python3',
        '/opt/homebrew/bin/python3',
        '/usr/local/bin/python3',
    }

    for _, candidate in ipairs(candidates) do
        if LrFileUtils.exists(candidate) and pythonHasDependencies(candidate) then
            return candidate
        end
    end

    local fromPath = captureShellOutput('/bin/zsh -l -c "command -v python3"')
    if fromPath and pythonHasDependencies(fromPath) then
        return fromPath
    end

    return nil
end

local function findExiftool()
    local candidates = {
        '/opt/homebrew/bin/exiftool',
        '/usr/local/bin/exiftool',
        '/opt/local/bin/exiftool',
    }

    for _, candidate in ipairs(candidates) do
        if LrFileUtils.exists(candidate) then
            return candidate
        end
    end

    local fromPath = captureShellOutput('/bin/zsh -l -c "command -v exiftool"')
    if fromPath and LrFileUtils.exists(fromPath) then
        return fromPath
    end

    return nil
end

local function collectStacks(photos)
    local seen = {}
    local stacks = {}

    for _, photo in ipairs(photos) do
        local top = photo:getRawMetadata('topOfStackInFolderContainingPhoto')
        local key = top and top.localIdentifier or photo.localIdentifier

        if not seen[key] then
            seen[key] = true
            local members = photo:getRawMetadata('stackInFolderMembers')
            if members and #members > 1 then
                table.insert(stacks, members)
            end
        end
    end

    return stacks
end

-- Mode a) one or more stacks selected: sharpest photo per stack.
-- Mode b) no stacks, just loose photos selected: sharpest of the whole selection.
-- Returns groups, isSelectionMode.
local function determineGroups(photos)
    local stacks = collectStacks(photos)
    if #stacks > 0 then
        return stacks, false
    elseif #photos > 1 then
        return { photos }, true
    end
    return {}, false
end

local function scoreStack(members, pythonPath, exiftoolPath)
    local temp = LrPathUtils.getStandardFilePath('temp')
    local listPath = LrPathUtils.child(temp, 'wildlife-sharpness-input.txt')
    local outputPath = LrPathUtils.child(temp, 'wildlife-sharpness-output.txt')

    local pathToPhoto = {}
    local listFile, openError = io.open(listPath, 'w')
    if not listFile then
        return nil, 'Could not write temporary file: ' .. tostring(openError)
    end

    for _, photo in ipairs(members) do
        local path = photo:getRawMetadata('path')
        pathToPhoto[path] = photo
        listFile:write(path, '\n')
    end
    listFile:close()

    local command = string.format(
        '%s %s --exiftool %s %s > %s 2>&1',
        shellQuote(pythonPath),
        shellQuote(LrPathUtils.child(_PLUGIN.path, 'sharpness.py')),
        shellQuote(exiftoolPath),
        shellQuote(listPath),
        shellQuote(outputPath)
    )

    local exitCode = LrTasks.execute(command)
    local output = LrFileUtils.exists(outputPath) and LrFileUtils.readFile(outputPath) or ''

    if exitCode ~= 0 then
        return nil, 'Analysis failed (exit code ' .. tostring(exitCode) .. '):\n' .. output
    end

    local scored = {}
    local failures = {}

    for line in output:gmatch('[^\r\n]+') do
        local status, value, path = line:match('^(%u+)\t([^\t]*)\t(.+)$')
        local photo = path and pathToPhoto[path]

        if photo and status == 'OK' then
            table.insert(scored, { photo = photo, score = tonumber(value) })
        elseif photo and status == 'ERR' then
            table.insert(failures, LrPathUtils.leafName(path) .. ': ' .. value)
        end
    end

    if #scored == 0 then
        return nil, 'No photo could be analysed.\n' .. table.concat(failures, '\n')
    end

    return scored, nil
end

local function pickWinner(scored)
    local winner = scored[1]
    for _, entry in ipairs(scored) do
        if entry.score > winner.score then
            winner = entry
        end
    end
    return winner
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('pickSharpest', function(context)
        local catalog = LrApplication.activeCatalog()
        local groups, isSelectionMode = determineGroups(catalog:getTargetPhotos())

        if #groups == 0 then
            LrDialogs.message(
                'Nothing to compare',
                'Select one or more stacks (two or more photos each), ' ..
                'or select two or more individual photos.',
                'info'
            )
            return
        end

        local pythonPath = findPython()
        local exiftoolPath = findExiftool()

        if not pythonPath or not exiftoolPath then
            local missing = {}
            if not pythonPath then
                table.insert(missing, 'Python 3 with numpy and Pillow (e.g. a conda env named "lightroom")')
            end
            if not exiftoolPath then
                table.insert(missing, 'exiftool')
            end
            LrDialogs.message(
                'Required tool not found',
                'Could not locate:\n- ' .. table.concat(missing, '\n- ') ..
                '\n\nSee README.md for installation instructions.',
                'critical'
            )
            return
        end

        local progress = LrProgressScope({
            title = 'Analysing sharpness',
            functionContext = context,
        })
        progress:setCancelable(true)

        local results = {}
        local problems = {}

        for index, members in ipairs(groups) do
            if progress:isCanceled() then
                break
            end

            progress:setPortionComplete(index - 1, #groups)
            if isSelectionMode then
                progress:setCaption(string.format('Comparing %d photos', #members))
            else
                progress:setCaption(string.format(
                    'Stack %d of %d (%d photos)', index, #groups, #members
                ))
            end

            local scored, failure = scoreStack(members, pythonPath, exiftoolPath)
            if scored then
                table.insert(results, { members = members, winner = pickWinner(scored) })
            else
                table.insert(problems, failure)
            end
        end

        progress:done()

        if #results > 0 then
            catalog:withWriteAccessDo('Pick sharpest photo', function()
                for _, result in ipairs(results) do
                    for _, photo in ipairs(result.members) do
                        photo:setRawMetadata('pickStatus', 0)
                    end
                    result.winner.photo:setRawMetadata('pickStatus', 1)
                end
            end, { timeout = 30 })
        end

        if #problems > 0 then
            local summary
            if isSelectionMode then
                summary = (#results > 0) and 'Sharpest photo flagged.' or 'Analysis failed.'
            else
                summary = string.format('%d of %d stacks flagged.', #results, #groups)
            end
            LrDialogs.message(summary, table.concat(problems, '\n\n'), 'warning')
        end
    end)
end)
