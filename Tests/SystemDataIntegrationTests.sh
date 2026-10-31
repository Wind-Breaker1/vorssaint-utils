#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
set -euo pipefail
cd "$(dirname "$0")/.."
system_data_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/vorssaint-systemdata-tests.XXXXXX")
trap 'rm -rf "$system_data_test_dir"' EXIT
xcrun swiftc Sources/Vorssaint/Services/BoundedProcessRunner.swift \
    Sources/Vorssaint/Services/SystemData/*.swift \
    Tests/Fixtures/SystemData/Integration.swift -o "$system_data_test_dir/check"
"$system_data_test_dir/check"
