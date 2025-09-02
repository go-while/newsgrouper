# GitHub Actions Workflows

This directory contains GitHub Actions workflows for the Newsgrouper project.

## Workflows

### 1. build-and-publish.yml

**Triggers:**
- Push to `main` or `master` branch
- New tags (e.g., `v1.0.0`)
- Manual trigger via workflow_dispatch

**Jobs:**

#### build-and-test
- Sets up Ubuntu environment with Tcl and dependencies
- Validates all `.tcl` files for basic syntax
- Checks executable scripts and configuration samples
- Creates application package (tar.gz)
- Uploads build artifacts

#### container-build
- Builds Docker container image
- Publishes to GitHub Container Registry (`ghcr.io`)
- Only runs on main branch or tags

#### release
- Creates GitHub releases for tags
- Attaches source package to release
- Only runs for tagged versions

### 2. test.yml

**Triggers:**
- Pull requests to `main` or `master`
- Manual trigger via workflow_dispatch

**Features:**
- Lightweight validation for PRs
- Tcl file syntax checking
- Project structure verification
- No container building or publishing

## Usage

### For Development
1. Create pull requests - the `test.yml` workflow will validate your changes
2. Merge to main branch - the `build-and-publish.yml` workflow will build and publish containers

### For Releases
1. Create a git tag: `git tag v1.0.0`
2. Push the tag: `git push origin v1.0.0`
3. The workflow will automatically:
   - Build and test the application
   - Create a Docker container image
   - Create a GitHub release with source package

## Container Images

Published container images are available at:
- `ghcr.io/go-while/newsgrouper:main` (latest main branch)
- `ghcr.io/go-while/newsgrouper:v1.0.0` (specific version tags)

## Requirements

The workflows handle installation of:
- Tcl and Tcllib
- SQLite3
- Redis server (for container builds)
- Optional: TclTls, compface, mboxgrep

Note: The project requires Tcl 9.0. The workflows use Ubuntu 24.04 and automatically compile Tcl 9.0 from source, so no manual upgrade is needed.

## Configuration

The workflows use sample configuration files and don't require actual NNTP server access for building/testing. For runtime configuration, see the main README file.