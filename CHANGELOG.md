# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2025-07-28

### Added
- Comprehensive documentation throughout the codebase with detailed doc comments
- Full NIP-04 encryption/decryption support (deprecated but functional)
- Full NIP-44 encryption/decryption support (modern standard)
- Browser interface for encryption/decryption operations
- Availability checking with caching for browser extensions
- Error handling and caching for unavailable extensions
- Enhanced HTML interface with encryption operation support

### Changed
- **BREAKING**: Renamed `initialize()` method to `signIn()` for better API consistency
- **BREAKING**: Renamed `dispose()` method to `signOut()` for better API consistency
- Updated method signatures to match the models package Signer interface
- Improved error handling throughout the application
- Enhanced browser interface with better user experience
- Updated dependency versions in pubspec.lock

### Fixed
- Implemented previously missing NIP-04 and NIP-44 encryption methods
- Improved error handling and browser management
- Better resource cleanup and memory management

### Security
- Added support for NIP-44 encryption (recommended over deprecated NIP-04)
- Proper handling of encryption/decryption operations through browser extensions

## [0.1.3] - Previous Release
- Initial stable release with basic signing functionality 