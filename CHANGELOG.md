# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- Outgoing SMS notices sent via the Twilio Messages API, replacing the unmaintained SMS::Send::Twilio driver ( fixes notices failing on characters outside Latin-1, e.g. "Can't escape \x{2013}" )
- Delivery status callbacks from Twilio update the notice status and failure code in Koha
- Plugin table storing Twilio message ids and delivery statuses, purged nightly after a configurable retention period
- Credentials are imported from an existing sms_send/Twilio.yaml driver config at install time

### Changed
- Renamed plugin from "Twilio Interactive SMS" to "Twilio SMS"
- Interactive SMS replies now encode message bodies as UTF-8 before sending

## [2.1.43] - 2021-03-01
### Changed
- Updated Koha community git repo address
- Added plugin hook for nightly actions

## [2.1.37] - 2020-04-15
### Changed
- A bug in github-action-koha-plugin-create-kpz meant the README.md and CHANGELOG.md files were not added to the kpz file. This should now be fixed.

## [2.1.36] - 2020-04-15
### Added
- Added CHANGELOG.md and README.md to release artifacts.

### Changed
- A bug in github-action-koha-plugin-create-kpz meant the README.md and CHANGELOG.md files were not added to the kpz file. This should now be fixed.

## [2.1.35] - 2020-04-15
### Added
- Added this changelog.

### Changed
- No changes in this release.

### Removed
- No removals in this release.
