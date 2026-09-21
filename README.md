# Wildlife Sharpness Analysis

A Lightroom Classic plug-in that picks the sharpest photo out of a burst of wildlife shots, so you don't have to zoom into every frame by hand.

## How it works

The plug-in adds a menu item **Library → Plug-in Extras → Pick Sharpest in Stack**.

It looks at your current selection in two ways:

- **Stack mode** — if one or more stacks are selected, the plug-in scores every photo in each stack and flags the sharpest one as the **Pick**, per stack.
- **Selection mode** — if no stacks are involved but you selected two or more loose photos, they're treated as a single burst and the sharpest one is flagged.

For each candidate photo, [PickSharpest.lua](PickSharpest.lua) hands the file paths to [sharpness.py](sharpness.py), which does the actual scoring:

1. It extracts the embedded full-resolution JPEG from the raw file via `exiftool` (`JpgFromRaw`, falling back to `PreviewImage`), so no raw decoding is needed.
2. The image is converted to grayscale and a Laplacian filter is applied to measure local contrast/edge strength.
3. The image is split into an 18×12 grid of tiles. If the raw file has exactly one valid autofocus area recorded (`ValidAFPoints == 1`), tiles overlapping that AF area have their score multiplied by a weight of 3 before ranking.
4. The **3 sharpest tiles** (after AF weighting) are averaged into the final score.

The reason for scoring only the sharpest tiles instead of the whole frame: wildlife backgrounds (grass, branches, foliage) are often high-frequency and would otherwise dominate a whole-image sharpness score. Focusing on the best-focused region makes the score track the subject (e.g. the animal's eye/head) instead of the background. The AF weighting nudges that selection towards the camera's own idea of where the subject is, without ignoring the rest of the frame — if the actually sharpest tiles lie outside the AF area (e.g. the AF hunted or the subject moved after focus lock), they can still outweigh a 3x-boosted background tile and win the ranking.

Scores are only meaningful *within* one burst/stack — they are not an absolute sharpness metric across different scenes.

The winning photo of each group gets its Lightroom **Pick** flag set to 1; all other members of that group are set to 0 (rejected/none).

## Requirements

- Lightroom Classic
- Python 3 with `numpy` and `Pillow` installed
- `exiftool`

## Installation

### 1. Install Python (Miniforge/conda)

If you don't already have a suitable Python environment, install Miniforge (native arm64 conda-forge distribution):

```bash
curl -L -O "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname)-$(uname -m).sh"
bash "Miniforge3-$(uname)-$(uname -m).sh"
```

Restart your terminal afterwards so `conda` is available on your `PATH`.

### 2. Create a dedicated environment and install the required packages

```bash
conda create -n lightroom -c conda-forge python=3.12 numpy pillow
```

Verify it works:

```bash
conda activate lightroom
python3 -c "import numpy, PIL; print(numpy.__version__, PIL.__version__)"
```

The plug-in auto-detects this environment by name (`lightroom`) under the common Miniforge/Miniconda/Anaconda install locations, so no manual configuration is needed as long as it's called `lightroom`.

### 3. Install exiftool

```bash
brew install exiftool
```

Verify it works:

```bash
which exiftool
```

### 4. Install the plug-in in Lightroom Classic

1. In Lightroom Classic, go to **File → Plug-in Manager**.
2. Click **Add**.
3. Select this folder (`WildlifeSharpnessAnalysis.lrplugin`).
4. Confirm the plug-in shows up as installed and enabled.

## Usage

1. In the Library, select either:
   - one or more **stacks** (two or more photos each), or
   - two or more **loose photos** (no stacking required) that belong to the same burst.
2. Go to **Library → Plug-in Extras → Pick Sharpest in Stack**.
3. Wait for the progress bar to finish. The sharpest photo per stack/selection is flagged as the Pick; the rest are unflagged.

The plug-in locates Python (a conda env named `lightroom` with `numpy`/`Pillow`, checked under the common Miniforge/Miniconda/Anaconda locations) and `exiftool` (checked under `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, and finally your login shell's `PATH`) automatically — no paths to configure. If either can't be found, or if a photo can't be analyzed, the plug-in shows a dialog explaining what went wrong.
