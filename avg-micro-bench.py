#!/usr/bin/env python3

import sys
import subprocess
import shlex
from collections import defaultdict

def print_usage():
    print(f"Usage: {sys.argv[0]} [runs] [command...]")
    print(f"  runs        Number of times to execute (default: 5)")
    print(f"  command...  Custom command to execute. If not provided, defaults to:")
    print(f"              ./lkvm-static run -k /home/jianlin/kvm-unit-tests/arm/micro-bench.flat -c 2 -m 1024 ...")
    print(f"\nExample:")
    print(f"  {sys.argv[0]} 10")
    print(f"  {sys.argv[0]} 5 ./lkvm-static run -k custom.flat -c 4")

def main():
    args = sys.argv[1:]
    runs = 5
    
    if args and args[0] in ('-h', '--help'):
        print_usage()
        sys.exit(0)

    # Try parsing the first argument as integer (number of runs)
    if args:
        try:
            runs = int(args[0])
            command = args[1:]
        except ValueError:
            command = args
    else:
        command = []

    if not command:
        # Default command exactly as used before
        command_str = "./lkvm-static run -k /home/jianlin/kvm-unit-tests/arm/micro-bench.flat -c 2 -m 1024 -nodefaults -p 'mmio-addr=0x1001000' -n mode=none"
        # Parse the string into proper pieces (handling the quotes correctly)
        command = shlex.split(command_str)

    print(f"Executing {runs} times:")
    print(" ".join(shlex.quote(c) for c in command))
    print()

    # Dictionary to store results: { 'test_name': [val1, val2, ...] }
    results = defaultdict(list)

    for i in range(1, runs + 1):
        print(f"===========================================")
        print(f" Run {i} / {runs}")
        print(f"===========================================")
        
        try:
            # We use Popen so we can read the stdout line-by-line while streaming it
            # Combining stdout and stderr means both normal and error messages show perfectly
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1
            )
        except FileNotFoundError:
            print(f"Error: command not found: {command[0]}")
            sys.exit(1)
            
        parse_mode = False
        
        # Iterate over the live output line-by-line
        for line in process.stdout:
            # Print to console directly so you can monitor the execution
            sys.stdout.write(line)
            sys.stdout.flush()

            line_stripped = line.strip()
            
            # The tests section typically starts after dashes
            if line_stripped.startswith('----'):
                parse_mode = True
                continue
            
            # We can optionally stop parsing on exit, though not strictly required
            if line_stripped.startswith('EXIT:'):
                parse_mode = False
                continue
                
            if parse_mode:
                if 'skipped' in line_stripped:
                    continue
                if line_stripped.startswith('Info:') or line_stripped.startswith('Warning:'):
                    continue
                if not line_stripped:
                    continue
                
                parts = line_stripped.split()
                # We expect at least the test name, and multiple metrics
                if len(parts) >= 3:
                    name = parts[0]
                    # The average response is on the last column based on standard output
                    avg_ns_str = parts[-1]
                    try:
                        avg_ns_val = float(avg_ns_str)
                        results[name].append(avg_ns_val)
                    except ValueError:
                        # Value wasn't a float, maybe format was weird for this line
                        pass
        
        # Ensure the process cleanly exited and closed output streams
        process.wait()
        print()

    # Finally compute and print the aggregate averages
    print("===========================================================")
    print(f" Average Results over {runs} runs")
    print("===========================================================")
    print(f"{'name':<35} {'avg ns (overall)':>20}")
    print("-" * 56)

    if not results:
        print("     [No valid data collected in output]")
    else:
        for name in sorted(results.keys()):
            vals = results[name]
            if vals:
                avg = sum(vals) / len(vals)
                print(f"{name:<35} {avg:>20.2f}")

if __name__ == '__main__':
    main()
