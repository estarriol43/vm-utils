#!/usr/bin/env python3

import sys
import subprocess
import shlex
import argparse
import csv
import os
from collections import defaultdict

def main():
    parser = argparse.ArgumentParser(
        description="Run kvm-unit-tests micro-benchmark multiple times and compute averages.",
        usage="%(prog)s [-n RUNS] [-r RESULT_DIR] [-- command ...]"
    )
    parser.add_argument('-n', '--runs', type=int, default=5, help="Number of times to execute (default: 5)")
    parser.add_argument('-r', '--result', type=str, help="Path to output folder for saving CSV files and logs")
    
    # parse_known_args separates known flags (-n, -r) from the custom benchmark command
    args, unknown = parser.parse_known_args()
    
    command = unknown
    
    # If the user uses '--' to prevent argparse from interpreting flags, strip it
    if command and command[0] == '--':
        command = command[1:]

    if not command:
        # Default command exactly as used before
        command_str = "./lkvm-static run -k /home/jianlin/kvm-unit-tests/arm/micro-bench.flat -c 2 -m 1024 -nodefaults -p 'mmio-addr=0x1001000' -n mode=none"
        command = shlex.split(command_str)

    print(f"Executing {args.runs} times:")
    print(" ".join(shlex.quote(c) for c in command))
    
    log_file_obj = None
    if args.result:
        # Create output directory if it doesn't already exist
        os.makedirs(args.result, exist_ok=True)
        print(f"Directory ready for CSV and log outputs: {args.result}/")
        
        # Open a log file to save all standard output and standard error
        log_path = os.path.join(args.result, "console_output.log")
        try:
            log_file_obj = open(log_path, 'w')
        except Exception as e:
            print(f"Warning: Failed to create log file at {log_path}: {e}")
            
    print()

    # Dictionary to store all results: { 'test_name': [val_r1, val_r2, val_r3... ] }
    # Initiated with Nones so that if a test skips one round, columns still perfectly align!
    results = defaultdict(lambda: [None] * args.runs)

    for i in range(args.runs):
        round_idx = i + 1
        
        # Capture the header boundary into both standard output and the log file
        header_str = f"===========================================\n Run {round_idx} / {args.runs}\n===========================================\n"
        sys.stdout.write(header_str)
        if log_file_obj:
            log_file_obj.write(header_str)
        
        try:
            # We use Popen so we can read the stdout line-by-line while streaming it
            # Using stderr=subprocess.STDOUT combines stdout and stderr perfectly in sync
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1
            )
        except FileNotFoundError:
            err_msg = f"Error: command not found: {command[0]}\n"
            sys.stdout.write(err_msg)
            if log_file_obj:
                log_file_obj.write(err_msg)
                log_file_obj.close()
            sys.exit(1)
            
        parse_mode = False
        
        # Iterate over the live output line-by-line
        for line in process.stdout:
            # Print to console directly so you can monitor the execution
            sys.stdout.write(line)
            sys.stdout.flush()
            
            # Write immediately to the log output as well
            if log_file_obj:
                log_file_obj.write(line)
                log_file_obj.flush()

            line_stripped = line.strip()
            
            # The tests section typically starts after dashes
            if line_stripped.startswith('----'):
                parse_mode = True
                continue
            
            # We can optionally stop parsing on exit
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
                        # Store in the exact array index for this round
                        results[name][i] = avg_ns_val
                    except ValueError:
                        # Value wasn't a float, maybe format was weird for this line
                        pass
        
        # Ensure the process cleanly exited and closed output streams
        process.wait()
        
        sys.stdout.write("\n")
        if log_file_obj:
            log_file_obj.write("\n")

    # Finally compute and print the aggregate averages
    footer_str = (
        "===========================================================\n"
        f" Average Results over {args.runs} runs\n"
        "===========================================================\n"
        f"{'name':<35} {'avg ns (overall)':>20}\n"
        "-----------------------------------------------------------\n"
    )
    sys.stdout.write(footer_str)
    if log_file_obj:
        log_file_obj.write(footer_str)

    if not results:
        msg = "     [No valid data collected in output]\n"
        sys.stdout.write(msg)
        if log_file_obj:
            log_file_obj.write(msg)
    else:
        # Compute and print averages
        avg_results = {}
        for name in sorted(results.keys()):
            valid_vals = [v for v in results[name] if v is not None]
            if valid_vals:
                avg = sum(valid_vals) / len(valid_vals)
                avg_results[name] = avg
                
                row_str = f"{name:<35} {avg:>20.2f}\n"
                sys.stdout.write(row_str)
                if log_file_obj:
                    log_file_obj.write(row_str)

        if args.result:
            sys.stdout.write("\n")
            # 1) Save the consolidated rounds CSV table
            rounds_csv_path = os.path.join(args.result, "all_rounds.csv")
            try:
                with open(rounds_csv_path, 'w', newline='') as f:
                    writer = csv.writer(f)
                    header = ['name'] + [f"round_{j+1}" for j in range(args.runs)]
                    writer.writerow(header)
                    for name in sorted(results.keys()):
                        row = [name]
                        for val in results[name]:
                            row.append(f"{val:.2f}" if val is not None else "N/A")
                        writer.writerow(row)
                sys.stdout.write(f"[+] Successfully saved all rounds table to: {rounds_csv_path}\n")
            except Exception as e:
                sys.stdout.write(f"[-] Failed to save rounds CSV: {e}\n")

            # 2) Save the traditional overall average CSV
            avg_csv_path = os.path.join(args.result, "average.csv")
            try:
                if avg_results:
                    with open(avg_csv_path, 'w', newline='') as f:
                        writer = csv.writer(f)
                        writer.writerow(['name', 'avg ns (overall)'])
                        for name in sorted(avg_results.keys()):
                            writer.writerow([name, f"{avg_results[name]:.2f}"])
                    sys.stdout.write(f"[+] Successfully saved overall average to:  {avg_csv_path}\n")
            except Exception as e:
                sys.stdout.write(f"[-] Failed to save average CSV: {e}\n")
                
            # Acknowledge the log file success
            sys.stdout.write(f"[+] Successfully saved console logs to:       {log_path}\n")

    if log_file_obj:
        log_file_obj.close()

if __name__ == '__main__':
    main()
