#!/usr/bin/env python3

import json
import os
import sys
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path
from datetime import datetime, timezone

if len(sys.argv) < 2:
    print(f"Usage: {sys.argv[0]} OUTPUT_JSON [DERIVED_DATA_PATH]", file=sys.stderr)
    print("  OUTPUT_JSON       path to write skip-list JSON", file=sys.stderr)
    print("  DERIVED_DATA_PATH optional; Xcode DerivedData dir to search for .stringsdata (or set DERIVED_DATA_PATH env)", file=sys.stderr)
    sys.exit(1)

out_path = Path(sys.argv[1])
derived_data_arg = sys.argv[2] if len(sys.argv) > 2 else None

def parse_xliff(path):
    """Parse an XLIFF file and return a list of (key, value) tuples."""
    entries = []
    try:
        tree = ET.parse(path)
        root = tree.getroot()
        
        # Detect namespace
        ns = ''
        if root.tag.startswith('{'):
            ns = root.tag.split('}')[0] + '}'
        
        # Find all trans-unit elements
        trans_units = root.findall(f'.//{ns}trans-unit') if ns else root.findall('.//trans-unit')
        
        for trans_unit in trans_units:
            # Get the source text
            source_elem = trans_unit.find(f'{ns}source') if ns else trans_unit.find('source')
            if source_elem is not None:
                # Handle text content
                source_text = ''
                if source_elem.text:
                    source_text = source_elem.text.strip()
                elif len(source_elem) > 0:
                    # If source contains nested elements, get all text
                    source_text = ''.join(source_elem.itertext()).strip()
                
                # Get the id (which is often the key)
                unit_id = trans_unit.get('id', '')
                
                # Use id as key if available, otherwise use source text
                key = unit_id if unit_id else source_text
                
                if source_text and key:
                    entries.append((key, source_text))
        
        return entries
    except Exception as e:
        print(f"⚠️  Failed to parse XLIFF {path}: {e}", file=sys.stderr)
        return []

def parse_stringsdata(path, repo_root):
    """Parse a .stringsdata file and return a list of entries with source file and location info."""
    entries = []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        source_file = data.get("source", "")
        
        # Normalize source file path to be relative to repo root if it's absolute
        if source_file:
            source_path = Path(source_file)
            if source_path.is_absolute():
                try:
                    # Try to make it relative to repo root
                    source_file = str(source_path.relative_to(repo_root))
                except ValueError:
                    # If it's not under repo root, keep as absolute but try to clean it up
                    # Remove common CI paths like /Users/runner/work/...
                    pass
            else:
                # Already relative, use as-is
                pass
        
        tables = data.get("tables", {})
        
        # Get entries from Localizable table
        localizable_table = tables.get("Localizable", [])
        
        for entry in localizable_table:
            key = entry.get("key", "")
            location = entry.get("location", {})
            starting_line = location.get("startingLine")
            starting_column = location.get("startingColumn")
            
            if key:  # Only include entries with keys
                entries.append({
                    "sourceFile": source_file,
                    "key": key,
                    "location": {
                        "startingLine": starting_line,
                        "startingColumn": starting_column
                    } if starting_line is not None or starting_column is not None else None
                })
        
        if entries:
            print(f"📋 Parsed {path.name}: found {len(entries)} entries from {source_file}", file=sys.stderr)
        
        return entries
    except Exception as e:
        print(f"⚠️  Failed to parse {path}: {e}", file=sys.stderr)
        return []

def parse_xcstrings(path):
    """Parse an .xcstrings file and return a list of (key, value) tuples."""
    entries = []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        strings = data.get("strings", {})
        source_lang = data.get("sourceLanguage", "en")
        
        print(f"📋 Parsing {path}: found {len(strings)} string entries, sourceLanguage={source_lang}", file=sys.stderr)

        skipped_count = 0
        skipped_samples = []
        
        for key, meta in strings.items():
            value = None
            
            # Try standard path: localizations[source_lang].stringUnit.value
            locs = meta.get("localizations", {})
            if locs:
                # Try the source language first; fall back to any localization.
                loc = locs.get(source_lang) or next(iter(locs.values()), {}) if locs else {}
                if loc:
                    unit = loc.get("stringUnit", {})
                    if unit:
                        value = unit.get("value")
            
            # If no value found via localizations, try alternative structures
            if not value:
                # Some entries might have the value directly in meta
                if "value" in meta:
                    value = meta["value"]
                # Or in a different structure
                elif "stringUnit" in meta:
                    value = meta["stringUnit"].get("value")
            
            # If still no value, use the key itself as the value
            # In Swift localization, when no localization exists, the key often IS the display value
            # This handles entries that don't have localizations yet but are still valid strings
            if not value:
                value = key
                skipped_count += 1
                # Collect sample keys that used fallback (for debugging)
                if len(skipped_samples) < 5:
                    skipped_samples.append((key, list(meta.keys())))
            
            # Always include the entry
            entries.append((key, value))
        
        if skipped_count > 0:
            print(f"   ℹ️  {skipped_count} entries had no localizations - used key as value (sample keys: {[k for k, _ in skipped_samples[:3]]})", file=sys.stderr)
        
        print(f"✅ Parsed {len(entries)} entries from {path}", file=sys.stderr)
        return entries
    except Exception as e:
        print(f"⚠️  Failed to parse {path}: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        return []

# 1. Find all .xcstrings, .xliff, and .stringsdata files
root = Path(".").resolve()
xcstrings_files = list(root.rglob("*.xcstrings"))
xliff_files = list(root.rglob("*.xliff"))
stringsdata_files = list(root.rglob("*.stringsdata"))

# Also search DerivedData if set (workflow uses isolated DerivedData outside repo root)
derived_data_path = derived_data_arg or os.environ.get("DERIVED_DATA_PATH")
if derived_data_path:
    dd = Path(derived_data_path)
    if dd.is_dir():
        extra = list(dd.rglob("*.stringsdata"))
        # Exclude noise (same filters as repo .stringsdata)
        extra = [f for f in extra if "SourcePackages" not in str(f) and "Products" not in str(f) and ".framework" not in str(f)]
        stringsdata_files = list(stringsdata_files) + extra
        if extra:
            print(f"🔍 Found {len(extra)} .stringsdata file(s) in DERIVED_DATA_PATH ({dd})", file=sys.stderr)
    else:
        print(f"⚠️  DERIVED_DATA_PATH not a directory: {derived_data_path}", file=sys.stderr)

# Exclude DerivedData and .git directories for .xcstrings and .xliff
xcstrings_files = [f for f in xcstrings_files if "DerivedData" not in str(f) and ".git" not in str(f)]
xliff_files = [f for f in xliff_files if "DerivedData" not in str(f) and ".git" not in str(f)]

# For .stringsdata, we want to include DerivedData (that's where they're generated)
# But exclude .git and SourcePackages
stringsdata_files = [f for f in stringsdata_files if ".git" not in str(f) and "SourcePackages" not in str(f) and "Products" not in str(f) and ".framework" not in str(f)]

print(f"🔍 Found {len(xcstrings_files)} .xcstrings file(s), {len(xliff_files)} .xliff file(s), and {len(stringsdata_files)} .stringsdata file(s)", file=sys.stderr)

# Also check for .xcloc bundles (which contain .xliff files inside)
xcloc_dirs = list(root.rglob("*.xcloc"))
for xcloc_dir in xcloc_dirs:
    if xcloc_dir.is_dir():
        # Look for .xliff files inside .xcloc bundles
        xliff_in_xcloc = list(xcloc_dir.rglob("*.xliff"))
        xliff_files.extend(xliff_in_xcloc)

if not xcstrings_files and not xliff_files and not stringsdata_files:
    print("No .xcstrings, .xliff, or .stringsdata files found; skip list will be empty.", file=sys.stderr)
    # Write structured output with metadata even for empty lists
    output = {
        "version": 1,
        "count": 0,
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "files": {}
    }
    out_path.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    sys.exit(0)

# First, parse .stringsdata files to get source file and location info
# Build a map: key -> (sourceFile, location)
stringsdata_map = {}
for path in stringsdata_files:
    parsed = parse_stringsdata(path, root)
    for entry in parsed:
        key = entry["key"]
        # If we have multiple .stringsdata files with the same key, keep the first one
        # (or we could merge locations, but for now first one wins)
        if key not in stringsdata_map:
            stringsdata_map[key] = {
                "sourceFile": entry["sourceFile"],
                "location": entry["location"]
            }

print(f"📊 Found location info for {len(stringsdata_map)} unique keys from .stringsdata files", file=sys.stderr)

# Build a map of key -> value from .xcstrings and .xliff files
value_map = {}

# Parse .xcstrings files to get values
for path in xcstrings_files:
    parsed = parse_xcstrings(path)
    for key, value in parsed:
        # Store value for this key (later files override earlier ones)
        value_map[key] = value

# Parse .xliff files to get values (will override .xcstrings if same key exists)
for path in xliff_files:
    parsed = parse_xliff(path)
    for key, value in parsed:
        value_map[key] = value

# Group entries by source file path (from project directory)
# Structure: files_dict[source_file_path] = [list of entries with key, value, and location]
files_dict = {}

# Process all stringsdata entries and enrich with values from .xcstrings/.xliff
for key, stringsdata_info in stringsdata_map.items():
    source_file = stringsdata_info["sourceFile"]
    location = stringsdata_info["location"]
    
    # Skip entries without a valid source file path
    if not source_file or source_file == "":
        continue
    
    # Get value from value_map, or use key as fallback
    value = value_map.get(key, key)
    
    # Create entry with key, value, and location
    entry = {
        "key": key,
        "value": value
    }
    
    # Add location if available
    if location:
        entry["location"] = location
    
    # Group by source file
    if source_file not in files_dict:
        files_dict[source_file] = []
    files_dict[source_file].append(entry)

# Fallback: when no .stringsdata files were found (e.g. build failed or DerivedData not in repo),
# populate the skip list from .xcstrings keys so the extractor can still skip known-localized strings.
if not files_dict and value_map:
    # Use the first .xcstrings file path (relative to root) as the synthetic "source file"
    synthetic_source = "Localizable.xcstrings"
    if xcstrings_files:
        try:
            synthetic_source = str(xcstrings_files[0].relative_to(root))
        except ValueError:
            pass
    files_dict[synthetic_source] = [
        {"key": key, "value": value}
        for key, value in value_map.items()
    ]
    print(
        f"📋 No .stringsdata location info found; using {len(value_map)} keys from .xcstrings as skip list (source: {synthetic_source})",
        file=sys.stderr,
    )

# Calculate total count
total_count = sum(len(entries) for entries in files_dict.values())

# Write structured output grouped by filepath
output = {
    "version": 1,
    "count": total_count,
    "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "files": files_dict
}
out_path.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"✅ Wrote skip list with {total_count} entries from {len(files_dict)} source files to {out_path}")

