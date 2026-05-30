# Repair Mac Catalyst slices of RN 0.83.x prebuilt xcframeworks.
#
# Upstream ships the Mac Catalyst slices of React.xcframework AND
# ReactNativeDependencies.xcframework (and potentially others) with a hybrid
# flat-iOS + Versions/A layout and none of the symlinks that tie them
# together. codesign first rejects this with "bundle format is ambiguous";
# after that's fixed, anything still sitting at the framework root that's
# not a recognised dev-only directory (e.g. ReactNativeDependencies_*.bundle)
# trips "unsealed contents present in the root directory of an embedded
# framework".
#
# For each maccatalyst-slice .framework whose Versions/A is a real directory:
#   - Move any non-symlinked top-level entry that isn't excluded by
#     CocoaPods' rsync filter (Headers / Modules / PrivateHeaders / VCS dirs)
#     and isn't Versions itself into Versions/A, so the macOS framework
#     bundle is properly sealed.
#   - Make Versions/Current a symlink to A.
#   - For each entry in Versions/A, replace the top-level entry with a
#     symlink into Versions/Current/<entry>.
#
# Top-level Headers/Modules are left in place — the rsync filter strips them
# before they reach the .app, and CocoaPods consumers read them via the
# xcframework-root path (React.xcframework/Headers/...), not via the slice.
#
# The [CP] Embed Pods Frameworks script detects symlinked binaries with
# `[ -L "$binary" ]` + `readlink` before lipo-stripping, so our symlinks
# survive the embed step. Idempotent — safe to re-run.

require 'fileutils'
require 'pathname'

RSYNC_FILTERED = %w[Headers Modules PrivateHeaders CVS .git .svn .hg].freeze

def _fix_maccatalyst_framework(framework, label_root)
  versions = framework.join('Versions')
  a_dir    = versions.join('A')
  current  = versions.join('Current')
  return unless a_dir.directory?

  # Move any non-symlinked, rsync-visible top-level entry into Versions/A so
  # codesign sees a properly sealed macOS framework.
  framework.children.each do |child|
    name = child.basename.to_s
    next if name == 'Versions'
    next if RSYNC_FILTERED.include?(name)
    next if child.symlink?

    target = a_dir.join(name)
    if target.exist?
      # Versions/A already owns the canonical copy — drop the duplicate.
      FileUtils.rm_rf(child.to_s)
    else
      FileUtils.mv(child.to_s, target.to_s)
    end
  end

  entries = a_dir.children.map { |c| c.basename.to_s }
  return if entries.empty?

  already_symlinked = current.symlink? &&
                      entries.all? { |e| framework.join(e).symlink? }

  unless already_symlinked
    if defined?(Pod::UI)
      Pod::UI.info "Repairing macOS bundle layout in #{framework.relative_path_from(label_root)}"
    end

    entries.each do |entry|
      top = framework.join(entry)
      FileUtils.rm_rf(top.to_s) if top.exist? || top.symlink?
    end
    FileUtils.rm_rf(current.to_s) if current.exist? || current.symlink?

    File.symlink('A', current.to_s)
    entries.each do |entry|
      File.symlink("Versions/Current/#{entry}", framework.join(entry).to_s)
    end
  end

  # Nested .bundle items inside Versions/A must be signed before the [CP] Embed
  # Pods Frameworks script signs the parent framework — codesign without
  # --deep won't recurse and bails with "code object is not signed at all".
  # The parent's identity doesn't need to match nested signatures, so ad-hoc
  # (-) signing is enough; the parent signing seals them in. Guarded on the
  # absence of _CodeSignature so re-runs are no-ops.
  a_dir.children.each do |child|
    next unless child.directory? && child.basename.to_s.end_with?('.bundle')
    next if child.join('_CodeSignature').directory?
    unless system('codesign', '--force', '--sign', '-', child.to_s, out: File::NULL, err: File::NULL)
      warn "fix_rncore_maccatalyst_bundle: failed to ad-hoc sign #{child}"
    end
  end
end

def fix_rncore_maccatalyst_bundle(installer)
  pods_root = Pathname.new(installer.sandbox.root.to_s)
  return unless pods_root.directory?

  Pathname.glob(pods_root.join('**', '*.xcframework')).each do |xcframework|
    xcframework.children.each do |slice|
      next unless slice.directory? && slice.basename.to_s.include?('maccatalyst')
      slice.children.each do |framework|
        next unless framework.directory? && framework.basename.to_s.end_with?('.framework')
        _fix_maccatalyst_framework(framework, pods_root)
      end
    end
  end
end
