return {
    LrSdkVersion = 10.0,
    LrSdkMinimumVersion = 6.0,

    LrToolkitIdentifier = 'de.jenskrause.wildlifesharpnessanalysis',
    LrPluginName = 'Wildlife Sharpness Analysis',

    LrLibraryMenuItems = {
        {
            title = 'Pick Sharpest Photo',
            file = 'PickSharpest.lua',
            enabledWhen = 'photosSelected',
        },
    },

    VERSION = { major = 0, minor = 1, revision = 0 },
}
