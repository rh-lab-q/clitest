#!/bin/sh
# doctest.sh - Automatic tests for shell script command lines
#
# Author:  Aurelio Jargas (http://aurelio.net)
# Created: 2013-07-24
# License: MIT
# GitHub:  https://github.com/aureliojargas/doctest.sh
#
# POSIX shell script:
#   This script was coded to be compatible with POSIX shells.
#   Tested in Bash 3.2, dash 0.5.5.1, ksh 93u 2011-02-08.
#   Note: Can't set -o posix nor POSIXLY_CORRECT: test env must be intact.
#
# Exit codes:
#   0  All tests passed, or normal operation (--help, --list, ...)
#   1  One or more tests have failed
#   2  An error occurred (file not found, invalid range, ...)
#
# Test environment:
#   By default, the tests will run in the current working directory ($PWD).
#   You can change to another dir normally using 'cd' inside the test file.
#   All the tests are executed in the same shell, using eval. Test data
#   such as variables and working directory will persist between tests.
#
# Namespace:
#   All variables and functions in this script are prefixed by 'tt_' to
#   avoid clashing with test's variables, functions, aliases and commands.

tt_my_name="$(basename "$0")"
tt_my_version='dev'

# Customization (if needed, edit here or use the command line options)
tt_prefix=''
tt_prompt='$ '
tt_inline_prefix='#→ '    # Problem with Unicode? Use '#=> ' or '### '
tt_diff_options='-u'
tt_color_mode='auto'      # auto, always, never
# End of customization

# --help message, keep it simple, short and informative
tt_my_help="\
Usage: $tt_my_name [options] <file ...>

Options:
  -1, --first                 Stop execution upon first failed test
  -l, --list                  List all the tests (no execution)
  -L, --list-run              List all the tests with OK/FAIL status
  -t, --test RANGE            Run specific tests, by number (1,2,4-7)
  -s, --skip RANGE            Skip specific tests, by number (1,2,4-7)
      --pre-flight COMMAND    Execute command before running the first test
      --post-flight COMMAND   Execute command after running the last test
  -q, --quiet                 Quiet operation, no output shown
  -v, --verbose               Show each test being executed
  -V, --version               Show program version and exit

Customization options:
      --color WHEN            Set when to use colors: auto, always, never
      --diff-options OPTIONS  Set diff command options (default: '$tt_diff_options')
      --inline-prefix PREFIX  Set inline output prefix (default: '$tt_inline_prefix')
      --prefix PREFIX         Set command line prefix (default: '$tt_prefix')
      --prompt STRING         Set prompt string (default: '$tt_prompt')"

# Temporary files (using files because <(...) is not portable)
tt_temp_dir="${TMPDIR:-/tmp}/doctest.$$"
tt_temp_file="$tt_temp_dir/temp.txt"
tt_test_ok_file="$tt_temp_dir/ok.txt"
tt_test_output_file="$tt_temp_dir/output.txt"

# Flags (0=off, 1=on), most can be altered by command line options
tt_debug=0
tt_quiet=0
tt_verbose=0
tt_list_mode=0
tt_list_run=0
tt_use_colors=0
tt_stop_on_first_fail=0
tt_separator_line_shown=0

# Globals (all variables are globals, for better portability)
tt_nr_files=0
tt_nr_total_tests=0
tt_nr_total_fails=0
tt_nr_total_skips=0
tt_nr_file_tests=0
tt_nr_file_fails=0
tt_nr_file_skips=0
tt_nr_file_ok=0
tt_files_stats=
tt_original_dir=$(pwd)
tt_pre_command=
tt_post_command=
tt_run_range=
tt_run_range_data=
tt_skip_range=
tt_skip_range_data=
tt_failed_range=
tt_test_file=
tt_input_line=
tt_line_number=0
tt_test_number=0
tt_test_line_number=0
tt_test_command=
tt_test_inline=
tt_test_mode=
tt_test_status=2
tt_test_output=
tt_test_diff=
tt_test_ok_text=

# Special handy chars
tt_tab='	'
tt_nl='
'

# Handle command line options
while test "${1#-}" != "$1"
do
	case "$1" in
		-q|--quiet      ) shift; tt_quiet=1 ;;
		-v|--verbose    ) shift; tt_verbose=1 ;;
		-l|--list       ) shift; tt_list_mode=1;;
		-L|--list-run   ) shift; tt_list_run=1;;
		-1|--first      ) shift; tt_stop_on_first_fail=1 ;;
		-t|--test       ) shift; tt_run_range="$1"; shift ;;
		-s|--skip       ) shift; tt_skip_range="$1"; shift ;;
		--color|--colour) shift; tt_color_mode="$1"; shift ;;
  		--debug         ) shift; tt_debug=1 ;;
		--pre-flight    ) shift; tt_pre_command="$1"; shift ;;
		--post-flight   ) shift; tt_post_command="$1"; shift ;;
		--diff-options  ) shift; tt_diff_options="$1"; shift ;;
		--inline-prefix ) shift; tt_inline_prefix="$1"; shift ;;
		--prompt        ) shift; tt_prompt="$1"; shift ;;
		--prefix        ) shift; tt_prefix="$1"; shift ;;
		-V|--version    ) printf '%s\n' "$tt_my_name $tt_my_version"; exit 0 ;;
		-h|--help       ) printf '%s\n' "$tt_my_help"; exit 0 ;;
		--) shift; break ;;
		*) break ;;
	esac
done

# Command line options consumed, now it's just the files
tt_nr_files=$#

# No files? Show help.
if test $tt_nr_files -eq 0
then
	printf '%s\n' "$tt_my_help"
	exit 0
fi


### Utilities

tt_clean_up ()
{
	rm -rf "$tt_temp_dir"
}
tt_message ()
{
	test $tt_quiet -eq 1 && return 0
	printf '%s\n' "$*"
	tt_separator_line_shown=0
}
tt_error ()
{
	printf '%s\n' "$tt_my_name: Error: $1" >&2
	tt_clean_up
	exit 2
}
tt_debug ()  # $1=id, $2=contents
{
	test $tt_debug -ne 1 && return 0
	if test INPUT_LINE = "$1"
	then
		# Original input line is all blue
		printf "${tt_color_blue}[%10s: %s]${tt_color_off}\n" "$1" "$2"
	else
		# Highlight tabs and inline prefix
		printf "${tt_color_blue}[%10s:${tt_color_off} %s${tt_color_blue}]${tt_color_off}\n" "$1" "$2" |
			sed "/LINE_CMD:/ s/$tt_inline_prefix/${tt_color_red}&${tt_color_off}/g" |
			sed "s/$tt_tab/${tt_color_green}<tab>${tt_color_off}/g"
	fi
}
tt_separator_line ()
{
	printf "%${COLUMNS}s" ' ' | tr ' ' -
}
tt_list_test ()  # $1=ok|fail|verbose
{
	# Show the output lines for --verbose, --list and --list-run
	case "$1" in
		ok)
			# Green line or OK stamp (--list-run)
			if test $tt_use_colors -eq 1
			then
				tt_message "${tt_color_green}#${tt_test_number}${tt_tab}${tt_test_command}${tt_color_off}"
			else
				tt_message "#${tt_test_number}${tt_tab}OK${tt_tab}${tt_test_command}"
			fi
		;;
		fail)
			# Red line or FAIL stamp (--list-run)
			if test $tt_use_colors -eq 1
			then
				tt_message "${tt_color_red}#${tt_test_number}${tt_tab}${tt_test_command}${tt_color_off}"
			else
				tt_message "#${tt_test_number}${tt_tab}FAIL${tt_tab}${tt_test_command}"
			fi
		;;
		verbose)
			# Cyan line, no stamp (--verbose)
			tt_message "${tt_color_cyan}#${tt_test_number}${tt_tab}${tt_test_command}${tt_color_off}"
		;;
		*)
			# Normal line, no color, no stamp (--list)
			tt_message "#${tt_test_number}${tt_tab}${tt_test_command}"
		;;
	esac
}
tt_parse_range ()  # $1=range
{
	# Parse numeric ranges and output them in an expanded format
	#
	#     Supported formats             Expanded
	#     ------------------------------------------------------
	#     Single:  1                    :1:
	#     List:    1,3,4,7              :1:3:4:7:
	#     Range:   1-4                  :1:2:3:4:
	#     Mixed:   1,3,4-7,11,13-15     :1:3:4:5:6:7:11:13:14:15:
	#
	#     Reverse ranges and repeated/unordered numbers are ok.
	#     Later we will just grep for :number: in each test.

	case "$1" in
		# No range, nothing to do
		0 | '')
			return 0
		;;
		# Error: strange chars, not 0123456789,-
		*[!0-9,-]*)
			return 1
		;;
	esac

	# OK, all valid chars in range, let's parse them

	tt_part=
	tt_n1=
	tt_n2=
	tt_operation=
	tt_range_data=':'  # :1:2:4:7:

	# Loop each component: a number or a range
	for tt_part in $(echo "$1" | tr , ' ')
	do
		# If there's an hyphen, it's a range
		case "$tt_part" in
			*-*)
				# Error: Invalid range format, must be: number-number
				echo "$tt_part" | grep '^[0-9][0-9]*-[0-9][0-9]*$' > /dev/null || return 1

				tt_n1=${tt_part%-*}
				tt_n2=${tt_part#*-}

				tt_operation='+'
				test $tt_n1 -gt $tt_n2 && tt_operation='-'

				# Expand the range (1-4 => 1:2:3:4)
				tt_part=$tt_n1:
				while test $tt_n1 -ne $tt_n2
				do
					tt_n1=$(($tt_n1 $tt_operation 1))
					tt_part=$tt_part$tt_n1:
				done
				tt_part=${tt_part%:}
			;;
		esac

		# Append the number or expanded range to the holder
		test $tt_part != 0 && tt_range_data=$tt_range_data$tt_part:
	done

	test $tt_range_data != ':' && echo $tt_range_data
	return 0
}
tt_reset_test_data ()
{
	tt_test_command=
	tt_test_inline=
	tt_test_mode=
	tt_test_status=2
	tt_test_output=
	tt_test_diff=
	tt_test_ok_text=
}
tt_run_test ()
{
	tt_test_number=$(($tt_test_number + 1))
	tt_nr_total_tests=$(($tt_nr_total_tests + 1))
	tt_nr_file_tests=$(($tt_nr_file_tests + 1))

	# Run range on: skip this test if it's not listed in $tt_run_range_data
	if test -n "$tt_run_range_data" && test "$tt_run_range_data" = "${tt_run_range_data#*:$tt_test_number:}"
	then
		tt_nr_total_skips=$(($tt_nr_total_skips + 1))
		tt_nr_file_skips=$(($tt_nr_file_skips + 1))
		tt_reset_test_data
		return 0
	fi

	# Skip range on: skip this test if it's listed in $tt_skip_range_data
	# Note: --skip always wins over --test, regardless of order
	if test -n "$tt_skip_range_data" && test "$tt_skip_range_data" != "${tt_skip_range_data#*:$tt_test_number:}"
	then
		tt_nr_total_skips=$(($tt_nr_total_skips + 1))
		tt_nr_file_skips=$(($tt_nr_file_skips + 1))
		tt_reset_test_data
		return 0
	fi

	# List mode: just show the command and return (no execution)
	if test $tt_list_mode -eq 1
	then
		tt_list_test
		tt_reset_test_data
		return 0
	fi

	# Verbose mode: show the command that will be tested
	if test $tt_verbose -eq 1 && test $tt_list_run -eq 0
	then
		tt_list_test verbose
	fi

	#tt_debug EVAL "$tt_test_command"

	# Execute the test command, saving output (STDOUT and STDERR)
	eval "$tt_test_command" > "$tt_test_output_file" 2>&1

	#tt_debug OUTPUT "$(cat "$tt_test_output_file")"

	# The command output matches the expected output?
	case $tt_test_mode in
		output)
			printf %s "$tt_test_ok_text" > "$tt_test_ok_file"
			tt_test_diff=$(diff $tt_diff_options "$tt_test_ok_file" "$tt_test_output_file")
			tt_test_status=$?
		;;
		text)
			# Inline OK text represents a full line, with \n
			printf '%s\n' "$tt_test_inline" > "$tt_test_ok_file"
			tt_test_diff=$(diff $tt_diff_options "$tt_test_ok_file" "$tt_test_output_file")
			tt_test_status=$?
		;;
		eval)
			eval "$tt_test_inline" > "$tt_test_ok_file"
			tt_test_diff=$(diff $tt_diff_options "$tt_test_ok_file" "$tt_test_output_file")
			tt_test_status=$?
		;;
		lines)
			tt_test_output=$(sed -n '$=' "$tt_test_output_file")
			test -z "$tt_test_output" && tt_test_output=0
			test "$tt_test_output" -eq "$tt_test_inline"
			tt_test_status=$?
			tt_test_diff="Expected $tt_test_inline lines, got $tt_test_output."
		;;
		file)
			# Abort when ok file not found/readable
			if test ! -f "$tt_test_inline" || test ! -r "$tt_test_inline"
			then
				tt_error "cannot read inline output file '$tt_test_inline', from line $tt_line_number of $tt_test_file"
			fi

			tt_test_diff=$(diff $tt_diff_options "$tt_test_inline" "$tt_test_output_file")
			tt_test_status=$?
		;;
		regex)
			egrep "$tt_test_inline" "$tt_test_output_file" > /dev/null
			tt_test_status=$?

			# Test failed: the regex not matched
			if test $tt_test_status -eq 1
			then
				tt_test_diff="egrep '$tt_test_inline' failed in:$tt_nl$(cat "$tt_test_output_file")"

			# Regex errors are common and user must take action to fix them
			elif test $tt_test_status -eq 2
			then
				tt_error "egrep: check your inline regex at line $tt_line_number of $tt_test_file"
			fi
		;;
		perl)
			perl -0777 -ne "exit(!/$tt_test_inline/)" "$tt_test_output_file"
			tt_test_status=$?

			# Test failed: the regex not matched
			if test $tt_test_status -eq 1
			then
				tt_test_diff="Perl regex '$tt_test_inline' not matched in:$tt_nl$(cat "$tt_test_output_file")"

			# Regex errors are common and user must take action to fix them
			elif test $tt_test_status -gt 1
			then
				tt_error "check your inline Perl regex at line $tt_line_number of $tt_test_file"
			fi
		;;
		*)
			tt_error "unknown test mode '$tt_test_mode'"
		;;
	esac

	# Test failed :(
	if test $tt_test_status -ne 0
	then
		tt_nr_file_fails=$(($tt_nr_file_fails + 1))
		tt_nr_total_fails=$(($tt_nr_total_fails + 1))
		tt_failed_range="$tt_failed_range$tt_test_number,"

		# Decide the message format
		if test $tt_list_run -eq 1
		then
			# List mode
			tt_list_test fail
		else
			# Normal mode: show FAILED message and the diff
			if test $tt_separator_line_shown -eq 0  # avoid dups
			then
				tt_message "${tt_color_red}$(tt_separator_line)${tt_color_off}"
			fi
			tt_message "${tt_color_red}[FAILED #$tt_test_number, line $tt_test_line_number] $tt_test_command${tt_color_off}"
			tt_message "$tt_test_diff" | sed '1 { /^--- / { N; /\n+++ /d; }; }'  # no ---/+++ headers
			tt_message "${tt_color_red}$(tt_separator_line)${tt_color_off}"
			tt_separator_line_shown=1
		fi

		# Should I abort now?
		if test $tt_stop_on_first_fail -eq 1
		then
			tt_clean_up
			exit 1
		fi

	# Test OK
	else
		test $tt_list_run -eq 1 && tt_list_test ok
	fi

	tt_reset_test_data
}
tt_process_test_file ()
{
	# Reset counters
	tt_nr_file_tests=0
	tt_nr_file_fails=0
	tt_nr_file_skips=0
	tt_line_number=0
	tt_test_line_number=0

	# Loop for each line of input file
	# Note: changing IFS to avoid right-trimming of spaces/tabs
	# Note: read -r to preserve the backslashes
	while IFS='' read -r tt_input_line || test -n "$tt_input_line"
	do
		tt_line_number=$(($tt_line_number + 1))
		#tt_debug INPUT_LINE "$tt_input_line"

		case "$tt_input_line" in

			# Prompt alone: closes previous command line (if any)
			"$tt_prefix$tt_prompt" | "$tt_prefix${tt_prompt% }" | "$tt_prefix$tt_prompt ")
				#tt_debug 'LINE_$' "$tt_input_line"

				# Run pending tests
				test -n "$tt_test_command" && tt_run_test
			;;

			# This line is a command line to be tested
			"$tt_prefix$tt_prompt"*)
				#tt_debug LINE_CMD "$tt_input_line"

				# Run pending tests
				test -n "$tt_test_command" && tt_run_test

				# Remove the prompt
				tt_test_command="${tt_input_line#"$tt_prefix$tt_prompt"}"

				# Save the test's line number for future messages
				tt_test_line_number=$tt_line_number

				# This is a special test with inline output?
				if printf '%s\n' "$tt_test_command" | grep "$tt_inline_prefix" > /dev/null
				then
					# Separate command from inline output
					tt_test_command="${tt_test_command%"$tt_inline_prefix"*}"
					tt_test_inline="${tt_input_line##*"$tt_inline_prefix"}"

					#tt_debug NEW_CMD "$tt_test_command"
					#tt_debug OK_INLINE "$tt_test_inline"

					# Maybe the OK text has options?
					case "$tt_test_inline" in
						'--regex '*)
							tt_test_inline=${tt_test_inline#--regex }
							tt_test_mode='regex'
						;;
						'--perl '*)
							tt_test_inline=${tt_test_inline#--perl }
							tt_test_mode='perl'
						;;
						'--file '*)
							tt_test_inline=${tt_test_inline#--file }
							tt_test_mode='file'
						;;
						'--lines '*)
							tt_test_inline=${tt_test_inline#--lines }
							tt_test_mode='lines'
						;;
						'--eval '*)
							tt_test_inline=${tt_test_inline#--eval }
							tt_test_mode='eval'
						;;
						'--text '*)
							tt_test_inline=${tt_test_inline#--text }
							tt_test_mode='text'
						;;
						*)
							tt_test_mode='text'
						;;
					esac

					#tt_debug OK_TEXT "$tt_test_inline"

					# There must be a number in --lines
					if test "$tt_test_mode" = 'lines'
					then
						case "$tt_test_inline" in
							'' | *[!0-9]*)
								tt_error "--lines requires a number. See line $tt_line_number of $tt_test_file"
							;;
						esac
					fi

					# An empty inline parameter is an error user must see
					if test -z "$tt_test_inline" && test "$tt_test_mode" != 'text'
					then
						tt_error "empty --$tt_test_mode at line $tt_line_number of $tt_test_file"
					fi

					# Since we already have the command and the output, run test
					tt_run_test
				else
					# It's a normal command line, output begins in next line
					tt_test_mode='output'

					#tt_debug NEW_CMD "$tt_test_command"
				fi
			;;

			# Test output, blank line or comment
			*)
				#tt_debug 'LINE_*' "$tt_input_line"

				# Ignore this line if there's no pending test
				test -n "$tt_test_command" || continue

				# Required prefix is missing: we just left a command block
				if test -n "$tt_prefix" && test "${tt_input_line#"$tt_prefix"}" = "$tt_input_line"
				then
					#tt_debug BLOCK_OUT "$tt_input_line"

					# Run the pending test and we're done in this line
					tt_run_test
					continue
				fi

				# This line is a test output, save it (without prefix)
				tt_test_ok_text="$tt_test_ok_text${tt_input_line#"$tt_prefix"}$tt_nl"

				#tt_debug OK_TEXT "${tt_input_line#"$tt_prefix"}"
			;;
		esac
	done < "$tt_temp_file"

	#tt_debug LOOP_OUT "\$tt_test_command=$tt_test_command"

	# Run pending tests
	test -n "$tt_test_command" && tt_run_test
}


### Init process

# Handy shortcuts for prefixes
case "$tt_prefix" in
	tab)
		tt_prefix="$tt_tab"
	;;
	0)
		tt_prefix=''
	;;
	[1-9] | [1-9][0-9])  # 1-99
		# convert number to spaces: 2 => '  '
		tt_prefix=$(printf "%${tt_prefix}s" ' ')
	;;
	*\\*)
		tt_prefix="$(printf %b "$tt_prefix")"  # expand \t and others
	;;
esac

# Will we use colors in the output?
case "$tt_color_mode" in
	always | yes | y)
		tt_use_colors=1
	;;
	never | no | n)
		tt_use_colors=0
	;;
	auto | a)
		# The auto mode will use colors if the output is a terminal
		# Note: test -t is in POSIX
		if test -t 1
		then
			tt_use_colors=1
		else
			tt_use_colors=0
		fi
	;;
	*)
		tt_error "invalid value '$tt_color_mode' for --color. Use: auto, always or never."
	;;
esac

# Set colors
# Remember: colors must be readable in dark and light backgrounds
# Customization: tweak the numbers after [ to adjust the colors
if test $tt_use_colors -eq 1
then
	tt_color_red=$(  printf '\033[31m')  # fail
	tt_color_green=$(printf '\033[32m')  # ok
	tt_color_blue=$( printf '\033[34m')  # debug
	tt_color_cyan=$( printf '\033[36m')  # verbose
	tt_color_off=$(  printf '\033[m')
fi

# Find the terminal width
# The COLUMNS env var is set by Bash (must be exported in ~/.bashrc).
# In other shells, try to use 'tput cols' (not POSIX).
# If not, defaults to 50 columns, a conservative amount.
: ${COLUMNS:=$(tput cols 2> /dev/null)}
: ${COLUMNS:=50}

# Parse and validate --test option value, if informed
tt_run_range_data=$(tt_parse_range "$tt_run_range")
if test $? -ne 0
then
	tt_error "invalid argument for -t or --test: $tt_run_range"
fi

# Parse and validate --skip option value, if informed
tt_skip_range_data=$(tt_parse_range "$tt_skip_range")
if test $? -ne 0
then
	tt_error "invalid argument for -s or --skip: $tt_skip_range"
fi

# Create temp dir, protected from others
umask 077 && mkdir "$tt_temp_dir" || tt_error "cannot create temporary dir: $tt_temp_dir"


### Real execution begins here

# Some preparing command to run before all the tests?
if test -n "$tt_pre_command"
then
	eval "$tt_pre_command" ||
		tt_error "pre-flight command failed with status=$?: $tt_pre_command"
fi

# For each input file in $@
for tt_test_file
do
	# Some tests may 'cd' to another dir, we need to get back
	# to preserve the relative paths of the input files
	cd "$tt_original_dir"

	# Abort when test file not found/readable
	if test ! -f "$tt_test_file" || test ! -r "$tt_test_file"
	then
		tt_error "cannot read input file: $tt_test_file"
	fi

	# In multifile mode, identify the current file
	if test $tt_nr_files -gt 1
	then
		if test $tt_list_mode -ne 1 && test $tt_list_run -ne 1
		then
			# Normal mode, show a message
			tt_message "Testing file $tt_test_file"
		else
			# List mode, show ------ and the filename
			tt_message $(tt_separator_line | cut -c 1-40) $tt_test_file
		fi
	fi

	# Convert Windows files (CRLF) to the Unix format (LF)
	# Note: the temporary file is required, because doing "sed | while" opens
	#       a subshell and global vars won't be updated outside the loop.
	sed "s/$(printf '\r')$//" "$tt_test_file" > "$tt_temp_file"

	# The magic happens here
	tt_process_test_file

	# Abort when no test found (and no active range with --test or --skip)
	if test $tt_nr_file_tests -eq 0 && test -z "$tt_run_range_data" && test -z "$tt_skip_range_data"
	then
		tt_error "no test found in input file: $tt_test_file"
	fi

	# Save file stats
	tt_nr_file_ok=$(($tt_nr_file_tests - $tt_nr_file_fails - $tt_nr_file_skips))
	tt_files_stats="$tt_files_stats$tt_nr_file_ok $tt_nr_file_fails $tt_nr_file_skips$tt_nl"
done

tt_clean_up

# Some clean up command to run after all the tests?
if test -n "$tt_post_command"
then
	eval "$tt_post_command"
fi

#-----------------------------------------------------------------------
# From this point on, it's safe to use non-prefixed global vars
#-----------------------------------------------------------------------

# Range active, but no test matched :(
if test $tt_nr_total_tests -eq $tt_nr_total_skips
then
	if test -n "$tt_run_range_data" && test -n "$tt_skip_range_data"
	then
		tt_error "no test found. The combination of -t and -s resulted in no tests."
	elif test -n "$tt_run_range_data"
	then
		tt_error "no test found for the specified number or range '$tt_run_range'"
	elif test -n "$tt_skip_range_data"
	then
		tt_error "no test found. Maybe '--skip $tt_skip_range' was too much?"
	fi
fi

# List mode has no stats
if test $tt_list_mode -eq 1 || test $tt_list_run -eq 1
then
	if test $tt_nr_total_fails -eq 0
	then
		exit 0
	else
		exit 1
	fi
fi

# Show stats
#   Data:
#     $tt_files_stats -> "100 0 23 \n 12 34 0"
#     $@ -> foo.sh bar.sh
#   Output:
#     ====    OK  FAIL  SKIP
#     ====   100     0    23  foo.sh
#     ====    12    34     0  bar.sh
if test $tt_nr_files -gt 1 && test $tt_quiet -ne 1
then
	echo
	printf '==== %5s %5s %5s\n' OK FAIL SKIP
	printf %s "$tt_files_stats" | while read ok fail skip
	do
		printf '==== %5s %5s %5s    %s\n' $ok $fail $skip "$1"
		shift
	done | sed 's/     0/     -/g'  # hide zeros
	echo
fi

# The final message: OK or FAIL?
#   OK: 123 of 123 tests passed
#   OK: 100 of 123 tests passed (23 skipped)
#   FAIL: 123 of 123 tests failed
#   FAIL: 100 of 123 tests failed (23 skipped)
skips=
if test $tt_nr_total_skips -gt 0
then
	skips=" ($tt_nr_total_skips skipped)"
fi
if test $tt_nr_total_fails -eq 0
then
	stamp="${tt_color_green}OK:${tt_color_off}"
	stats="$(($tt_nr_total_tests - $tt_nr_total_skips)) of $tt_nr_total_tests tests passed"
	tt_message "$stamp $stats$skips"
	exit 0
else
	test $tt_nr_files -eq 1 && tt_message  # separate from previous FAILED message

	stamp="${tt_color_red}FAIL:${tt_color_off}"
	stats="$tt_nr_total_fails of $tt_nr_total_tests tests failed"
	tt_message "$stamp $stats$skips"
	test $tt_test_file = 'testme.sh' && tt_message "-t ${tt_failed_range%,}"  # XXX dev helper, remove before release
	exit 1
fi
