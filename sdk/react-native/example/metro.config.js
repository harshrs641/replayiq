const path = require('path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

// The library lives one folder up (sdk/react-native) and is linked with
// "file:..": watch it, and resolve its react / react-native imports from this
// app's node_modules.
const library = path.resolve(__dirname, '..');

const config = {
  watchFolders: [library],
  resolver: {
    nodeModulesPaths: [path.resolve(__dirname, 'node_modules')],
    blockList: [new RegExp(`${library.replace(/[/\\]/g, '[/\\\\]')}[/\\\\]example[/\\\\]node_modules[/\\\\].*[/\\\\]example[/\\\\].*`)],
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
