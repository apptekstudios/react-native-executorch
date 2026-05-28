// Shared Expo config plugin: flip the generated Xcode project + Podfile so
// `expo prebuild` produces a Mac Catalyst-buildable app.
//
// Mirrors the in-repo edits applied to apps/bare-rn (which is not an Expo
// app and therefore has a tracked ios/ dir). For each app that consumes
// this plugin via plugins[] in app.json, on every prebuild we:
//
//   1. Pod target: set `:mac_catalyst_enabled => true` on the
//      `react_native_post_install` call so CocoaPods applies upstream's
//      Catalyst patches (frameworks linked correctly, simulator-only
//      pods filtered, etc).
//   2. App target: set SUPPORTS_MACCATALYST=YES +
//      DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER=NO on every
//      XCBuildConfiguration of the main app target, so Xcode's destination
//      list offers "My Mac (Mac Catalyst)" with the same bundle id used by
//      iOS.
//
// Both passes are idempotent — running `expo prebuild` twice is a no-op
// after the first.

const { withPodfile, withXcodeProject } = require('@expo/config-plugins');

function withMacCatalystPodfile(config) {
  return withPodfile(config, (cfg) => {
    let src = cfg.modResults.contents;

    if (/:mac_catalyst_enabled\s*=>\s*true/.test(src)) {
      return cfg;
    }

    if (/:mac_catalyst_enabled\s*=>\s*false/.test(src)) {
      src = src.replace(
        /:mac_catalyst_enabled\s*=>\s*false/g,
        ':mac_catalyst_enabled => true'
      );
    } else {
      // Inject the flag into the existing react_native_post_install call.
      // Match the call signature across newlines; capture everything up to
      // the closing paren so we can splice in a kwarg.
      src = src.replace(
        /react_native_post_install\(\s*([\s\S]*?)\)/m,
        (match, args) => {
          const trimmed = args.replace(/\s+$/, '');
          const sep = trimmed.endsWith(',') ? '' : ',';
          return `react_native_post_install(\n      ${trimmed}${sep}\n      :mac_catalyst_enabled => true\n    )`;
        }
      );
    }

    cfg.modResults.contents = src;
    return cfg;
  });
}

function withMacCatalystXcodeProject(config) {
  return withXcodeProject(config, (cfg) => {
    const project = cfg.modResults;
    const targetName = cfg.modRequest.projectName;

    const targets = project.pbxNativeTargetSection();
    let targetUuid;
    for (const [uuid, target] of Object.entries(targets)) {
      if (uuid.endsWith('_comment')) continue;
      if (target.name === targetName || target.name === `"${targetName}"`) {
        targetUuid = uuid;
        break;
      }
    }
    if (!targetUuid) return cfg;

    const configList = targets[targetUuid].buildConfigurationList;
    const configurations =
      project.pbxXCConfigurationList()[configList].buildConfigurations;
    const buildConfigSection = project.pbxXCBuildConfigurationSection();

    for (const ref of configurations) {
      const buildConfig = buildConfigSection[ref.value];
      if (!buildConfig || !buildConfig.buildSettings) continue;
      buildConfig.buildSettings.SUPPORTS_MACCATALYST = 'YES';
      buildConfig.buildSettings.DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER =
        'NO';
    }

    return cfg;
  });
}

module.exports = function withMacCatalyst(config) {
  config = withMacCatalystPodfile(config);
  config = withMacCatalystXcodeProject(config);
  return config;
};
