#!/usr/bin/env ruby
# frozen_string_literal: true
#
# appvault-setup.rb — one-command wiring of the AppVault in-place build phases into an Xcode project,
# so a client never has to touch Build Phases by hand.
#
# It adds (idempotently):
#   * an "AppVault Stage" Run Script phase BEFORE Compile Sources,
#   * an "AppVault Restore" Run Script phase as the LAST phase,
#   * ENABLE_USER_SCRIPT_SANDBOXING = NO on the target (required: the stage phase rewrites source).
# Re-running updates the existing phases instead of duplicating them.
#
# Usage:
#   ruby appvault-setup.rb <path/to/App.xcodeproj> [--target <TargetName>] [--appvault-dir <path>]
#
# --target        the app target to wire (default: the first application target).
# --appvault-dir  where the AppVault package lives. Default: the Swift Package Manager checkout
#                 (…/SourcePackages/checkouts/app-vault-ios). Pass this when you use a local path
#                 dependency, or set $APPVAULT_DIR in your environment at build time.
#
# Requires the `xcodeproj` gem:  gem install xcodeproj

require "xcodeproj"

# Ruby's default US-ASCII external encoding makes xcodeproj choke on any non-ASCII byte in the
# project file (e.g. a UTF-8 comment). Read/write as UTF-8.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

STAGE_NAME   = "AppVault Stage"
RESTORE_NAME = "AppVault Restore"

def die(msg)
  warn "error: #{msg}"
  exit 1
end

# --- parse args -------------------------------------------------------------------------------
project_path = nil
target_name  = nil
appvault_dir = nil
args = ARGV.dup
until args.empty?
  a = args.shift
  case a
  when "--target"       then target_name = args.shift
  when "--appvault-dir" then appvault_dir = args.shift
  when "-h", "--help"
    puts File.read(__FILE__).lines.grep(/^#/).map { |l| l.sub(/^# ?/, "") }.join
    exit 0
  else
    project_path = a
  end
end
die "pass the path to your .xcodeproj" if project_path.nil?
die "project not found: #{project_path}" unless File.exist?(project_path)

# Default to the SPM checkout; a local-path dependency should pass --appvault-dir.
appvault_default = appvault_dir || '${BUILD_DIR%/Build/*}/SourcePackages/checkouts/app-vault-ios'

def phase_script(cmd, appvault_default)
  what = cmd == "stage" ? "Obfuscate the configured packages in place before compiling." \
                        : "Restore the pristine source after compiling (working tree stays unchanged)."
  <<~SH
    # #{what}  (managed by appvault-setup.rb; safe to re-run)
    export APPVAULT_DIR="${APPVAULT_DIR:-#{appvault_default}}"
    INPLACE="$APPVAULT_DIR/Scripts/appvault-inplace.sh"
    if [ -f "$INPLACE" ]; then
      "$INPLACE" #{cmd}
    else
      echo "warning: AppVault not found at $APPVAULT_DIR — set APPVAULT_DIR; skipping #{cmd}."
    fi
  SH
end

project = Xcodeproj::Project.open(project_path)

target =
  if target_name
    project.targets.find { |t| t.name == target_name } ||
      die("no target named '#{target_name}' (have: #{project.targets.map(&:name).join(', ')})")
  else
    project.targets.find { |t| t.respond_to?(:product_type) && t.product_type == "com.apple.product-type.application" } ||
      die("no application target found; pass --target")
  end

# --- idempotency: drop any phases we previously added ----------------------------------------
target.build_phases.to_a.each do |ph|
  next unless ph.isa == "PBXShellScriptBuildPhase"
  ph.remove_from_project if [STAGE_NAME, RESTORE_NAME].include?(ph.display_name)
end

# --- stage: a shell phase placed BEFORE Compile Sources --------------------------------------
stage = project.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
stage.name = STAGE_NAME
stage.shell_path = "/bin/sh"
stage.shell_script = phase_script("stage", appvault_default)
stage.always_out_of_date = "1" if stage.respond_to?(:always_out_of_date=)
target.build_phases.unshift(stage)   # first => before Sources

# --- restore: a shell phase placed LAST ------------------------------------------------------
restore = project.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
restore.name = RESTORE_NAME
restore.shell_path = "/bin/sh"
restore.shell_script = phase_script("restore", appvault_default)
restore.always_out_of_date = "1" if restore.respond_to?(:always_out_of_date=)
target.build_phases << restore       # last

# --- build setting: allow the script to rewrite source files ---------------------------------
target.build_configurations.each do |config|
  config.build_settings["ENABLE_USER_SCRIPT_SANDBOXING"] = "NO"
end

project.save

puts "AppVault wired into target '#{target.name}':"
puts "  • '#{STAGE_NAME}' run-script phase added before Compile Sources"
puts "  • '#{RESTORE_NAME}' run-script phase added as the last phase"
puts "  • ENABLE_USER_SCRIPT_SANDBOXING = NO"
puts "  • AppVault location: #{appvault_dir || 'SPM checkout (override with $APPVAULT_DIR)'}"
puts "Done. Add an appvault-classes.yml with your packages, then just build."
