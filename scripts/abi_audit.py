#!/usr/bin/env python3
import sys
import os
import re
from lxml import etree

def parse_crc_int(crc_str):
    if re.match(r'0x[0-9a-fA-F]+', crc_str):
        return int(crc_str[2:], 16)
    return 0

def parse_xml(filepath):
    """Parses Android ABI XML file (used in 5.10)."""
    symbols = {}
    if not os.path.exists(filepath):
        return symbols
        
    with open(filepath, 'r', encoding="utf-8") as f:
        xml_root = etree.XML(f.read())
        for symbol in xml_root.xpath('.//elf-symbol'):
            name = symbol.get("name")
            crc = symbol.get("crc")
            if name and crc:
                symbols[name] = parse_crc_int(crc)
    return symbols

def parse_stg(filepath):
    """Parses Android STG file (used in 6.1+)."""
    symbols = {}
    if not os.path.exists(filepath):
        return symbols

    current_sym = {}
    with open(filepath, 'r', encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line == "elf_symbol {":
                current_sym = {}
            elif line == "}":
                if "name" in current_sym and "crc" in current_sym:
                    symbols[current_sym["name"]] = parse_crc_int(current_sym["crc"])
                current_sym = {}
            elif ":" in line and current_sym is not None:
                key, val = line.split(":", 1)
                current_sym[key.strip()] = val.strip().strip('"')
    return symbols

def parse_symvers(filepath):
    """Parses the generated vmlinux.symvers file."""
    symbols = {}
    if not os.path.exists(filepath):
        return symbols
        
    with open(filepath, 'r', encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                # Format: CRC SymbolName ...
                crc = parts[0]
                name = parts[1]
                symbols[name] = parse_crc_int(crc)
    return symbols

def main():
    if len(sys.argv) != 3:
        print("Usage: script.py <abi_file> <symvers_file>")
        sys.exit(1)

    abi_file = sys.argv[1]
    symvers_file = sys.argv[2]
    
    print(f"Comparing ABI: {abi_file} vs {symvers_file}")

    # Determine parser based on extension
    if abi_file.endswith('.xml'):
        expected_syms = parse_xml(abi_file)
    else:
        expected_syms = parse_stg(abi_file)

    actual_syms = parse_symvers(symvers_file)
    
    mismatches = []
    
    # Check for CRC mismatches
    common_keys = set(expected_syms.keys()) & set(actual_syms.keys())
    for name in common_keys:
        if expected_syms[name] != actual_syms[name]:
            mismatches.append((name, hex(expected_syms[name]), hex(actual_syms[name])))

    # Output results
    if not mismatches:
        print("Success: No CRC mismatches found.")
    else:
        print(f"Failure: Found {len(mismatches)} mismatches.")
        print(f"{'Symbol':<40} | {'Expected':<12} | {'Actual':<12}")
        print("-" * 70)
        for m in mismatches:
            print(f"{m[0]:<40} | {m[1]:<12} | {m[2]:<12}")

if __name__ == "__main__":
    main()
  
