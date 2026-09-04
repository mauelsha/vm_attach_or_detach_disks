#!/usr/bin/env bash
#
# Attach/detach/list a set of host block devices given by paths as
# virtio-scsi devices with given paramaters to/from/of a VM.
# Filters --host, --bus, --target and --lun apply to list and detach-disk for scsi.
#
# Typically a set of full or thin provisioned host logical volumes is used.
#
# See --help.
#

PS4='+ ${EPOCHREALTIME} ${FUNCNAME[0]}[$LINENO]: ' # -x

#
# Global default declarations+definitions.
#
declare version="1.0.0"

declare cmd="${0##*/}" # remove path from $0.
declare command=''
declare domain=''
declare -A scsi_devices=() # Keep track of device properties (key=sd:property_name, value=property_value).
declare -A dev_by_sd=() # All attached sd targets (key=sd,value=1).

# Associative array of 'bools' for command line options provided.
declare -A cli_options=()

# Associative array of all options (keys) with long options (values) as defined by help() extraction (see define_options())
declare -A all_options=()

# Arguments array (devices list after parsing command, domain, options and their arguments).
declare -a args=()

# Host, bus, target, lun identifiers.
declare -ar hbtl_params=( "host" "bus" "target" "lun" )

# All disk parameter identifiers including the above.
declare -ar disk_params_names=( ${hbtl_params[@]}  "logical_block_size" "physical_block_size" "cache" "io" "discard" "detect_zeroes" "shareable" )

# Device limits like host number per controller.
declare -Ar device_limits=(
	[host]=204                    # Maximum host# per virtio-scsi controller.
	[bus]=0                       # Maximum bus# per virtio-scsi host.
	[target]=255                  # Maximum target# per virtio-scsi bus.
	[lun]=16383                   # Maximum lun# per virtio-scsi target.
	[logical_block_size]=32768    # Maximum logical block size of device.
	[physical_block_size]=2097152 # Maximum physical block size of device.
)

# Cache, io, block sizes, ... disk/driver modes defaults.
declare -Ar disk_params_defaults=(
	# virtio-scsi "controller" (channel's restricted to 0).
	[host]=0
	[bus]=0 # Always on virtio-scsi
	[target]=0
	[lun]=0

	[logical_block_size]=512
	[physical_block_size]=512

	[cache]="none"
	[io]="threads"
	[discard]="unmap"
	[detect_zeroes]="unmap"

	[shareable]="yes"
)

# Declare and define adjustable copy.
declare key=''
declare -A disk_params=()
for key in "${!disk_params_defaults[@]}"; do disk_params["$key"]="${disk_params_defaults["$key"]}"; done
unset key

declare -Ar option_arg_ranges=(
	[host]="0|1|2|3|...|253"
	[bus]="0"
	[target]="0|1|...|255"
	[lun]="0|1|...|16383"
	[logical_block_size]="512|1024|2048|...|32768"
	[physical_block_size]="512|1024|2048|...|2097152"
	[cache]="none|writeback:wb|writethrough:wt|directsync:ds|unsafe"
	[detect_zeroes]="off|on|unmap"
	[discard]="ignore|unmap"
	[io]="native|threads"
	[shareable]="yes|no"
)

# Temporary files.
declare -r tmpf_disk_xml="$(mktemp)"
trap "rm -f $tmpf_disk_xml 2>/dev/null" EXIT

# Print a message to stdout.
_stdout()
{
	echo "$cmd -- $@"
}

# Print a message to stdout without lf.
_stdout_no_lf()
{
	echo -n "$cmd -- $@"
}

# Print a message to stdout if --verbose.
_stdout_verbose()
{
	(( ${cli_options[verbose]} )) && _stdout "$@"
}

# Print a message to stdout if --verbose.
_stdout_verbose_no_lf()
{
	(( ${cli_options[verbose]} )) && _stdout_no_lf "$@"
}

# Print a message to stderr.
_stderr()
{
	echo "$cmd -- $@" >&2
}

# Print a message to stderr without lf.
_stderr_no_lf()
{
	echo -n "$cmd -- $@" >&2
}

# Print a message to stderr and return a code.
_stderr_ret()
{
	_stderr "$@"
	return 1
}

# Create parametrized virtio-scsi device definition.
_create_disk_xml()
{
	local sdev="$1"
	local tdev="$2"
	local -i lun="${3:-0}"
	local wwn=''
	local serial=''

	wwn="$(printf "4711%03d%01d%03d%05d" "${disk_params[host]}" "${disk_params[bus]}" "${disk_params[target]}" "$lun")"
	serial="$(printf "%03d%01d%03d%05d" "${disk_params[host]}" "${disk_params[bus]}" "${disk_params[target]}" "$lun")"

	cat <<-EOF
	    <disk type='block' device='disk'>
	      <driver name='qemu' type='raw' cache='${disk_params[cache]}' discard='${disk_params[discard]}' detect_zeroes='${disk_params[detect_zeroes]}' io='${disk_params[io]}'/>
	      <source dev='$sdev'/>
	      <backingStore/>
	      <wwn>$wwn</wwn>
	      <serial>$serial</serial>
	      <blockio logical_block_size='${disk_params[logical_block_size]}' physical_block_size='${disk_params[physical_block_size]}'/>
	      <target dev='$tdev' bus='scsi'/>
	EOF
	[[ "${disk_params["shareable"]}" == "yes" ]] && echo "      <shareable/>"
	cat <<-EOF
	      <alias name='scsi${disk_params[host]}-${disk_params[bus]}-${disk_params[target]}-$lun'/>
	      <address type='drive' controller='${disk_params[host]}' bus='${disk_params[bus]}' target='${disk_params[target]}' unit='$lun'/>
	    </disk>
	EOF
}

#
# Help
#
# Is used to define the all_options hash array in define_options() which requires that all short options have a long version!
#
help()
{
	local h="Usage: $cmd [{attach-disk|detach-disk|list} <domain>] [path|target]...
		[-H|--host <id>[,<id>...] [-B|bus <id>[,<id>...]] [-T|--target <id>[,<id>...]] [-L|--lun <id>[,<id>...]]
		[-C|--cache <mode>] [-I|--io <mode>]
		[-d|--discard <type>] [-D|--detect_zeroes <type>]
		[-l|--logical_block_size <bytes>} [-p|--physical_block_size <bytes>]
		[-n|--noheading] [-S|--shareable <action>] [-h|--help] [-x|--device_defaults]
		[-q|--quiet] [-s|--short] [-V|--version] [-v|--verbose]...
   [-a|--all]                           detach-disk: Select all attached scsi devices on detach-disk, no paths/targets
   [-H|--host <id[,<id>...]]            detach-disk|list: Select scsi host id(s)   (default 0, multiple for 'list')
   [-B|--bus <id>[,<id>...]]            detach-disk|list: Select scsi bus id(s)    (default 0, multiple for 'list')
   [-T|--target <id>[,<id>...]]         detach-disk|list: Select scsi target id(s) (default 0, multiple for 'list')
   [-L|--lun <id>[,<id>...]]            detach-disk|list: Select scsi lun id(s) or select free one(s) on attach (multiple for 'list')
   [-q|--quiet]                         list: No output with 0 for devices attached, 1 none (useful to check for devices with -H, -B, -T, -L)
   [-s|--short]                         list: Short output,  mutually exclsive with --quiet
   [-C|--cache (none|wb|writeback|wt|writethrough|directsync|unsafe)]  attach-disk: Set caching option (default: none)
   [-I|--io (threads,native)]           attach-disk: Set I/O option (default: threads)
   [-d|--discard (ignore|unmap)]        attach-disk: Configure discard processing (default: unmap)
   [-D|--detect_zeroes (off|on|unmap)]  attach-disk: Configure detect zeroes processing (default: unmap)
   [-l|--logical_block_size <bytes>]    attach-disk: Logical block size in power-of-2 bytes for the set of block devices (default: 512)
   [-p|--physical_block_size <bytes>]   attach-disk: Physical block size in power-of-2 bytes for the set of block devices (default: 512)
   [-n|--noheading                      list: Avoid header line
   [-S|--shareable (yes|no)             attach-disk: Shareable option (default: yes)
   [-x|--device_defaults]               Show device defaults
   [-h|--help]                          This help synopsis
   [-V|--version]                       Show version
   [-v|--verbose]...                    Enable verbose output

Paths/targets/ids may contain glob patterns, including character lists, ranges, and ?,
such as [adeu-y0-4?].  E.g. [14-7] sd[a-z], sd[ac]d[d-h]? or /dev/vg/lv?[0-9].

Environment variable 'vm' can be used to define the default domain for the command."

	echo "$h"
}

_get_long_option()
{
	local so="$1"
	local -n lo2_ref="$2"
	local lo=''

	lo2_ref=''
	[[ ${#so} == 1 ]] || return 1

	for lo in "${!all_options[@]}"; do
		if [[ "$so" == "${all_options["$lo"]}" ]]; then
			lo2_ref="$lo"
			return 0
		fi
	done

	return 1
}

# Helper to check for both short and long option returning the long option name if any.
_is_option()
{
	local ov="$1"
	local lo="$2"
	local -n lo1_ref="$3"
	local lo2=''
	local len=0
	local -i r=1 # Assume bogus option.

	lo1_ref=''
	[[ "${ov:0:1}" == "-" ]] || return 1

	ov="${ov#-}"

	case "$ov" in
	-*) # long option
		ov="${ov#-}" # Remove second '-'.
		len="${#ov}"

		for lo in "${!all_options[@]}"; do
			if [[ "$ov" == "${lo:0:$len}" ]]; then
				lo1_ref="$lo"
				r=0
				break
			fi
		done
		;;
	*) # short option
		_get_long_option "$ov" lo2
		r=$?
		lo1_ref="$lo2"
	esac

	return $r
}

# Check if the option being tried to parse is a valid short or long one.
is_option()
{
	local ov="$1"
	local -n lo_ref="$2"
	local lo_t=''
	local lo1=''

	# Bail out if it's no option identified by '-' or '--' prefix.
	[[ "${ov:0:1}" == "-" ]] || return 1

	for lo_t in "${!all_options[@]}"; do
		if _is_option "$ov" "$lo_t" lo1; then
			lo_ref="$lo1"
			return 0
		fi
	done

	return 1
}

# Check a long option semantically.
# $1 = name of caller's variable holding the long option (e.g. "lo")
# $2 = name of caller's variable holding the "-x|--xxx" display string (e.g. "opt")
# $3 = name of caller's variable to receive the arg-shift count
#
# Optional arguments to go past checking and setting an option with an option argument:
# $4 = the actual option argument value
# $5 = human readable requirement message for the value
# $6 = validation regex for the value string
_check_option()
{
	local -n lo_ref="$1"
	local -n msg_ref="$2"
	local -n nshift_ref="$3"
	local v=''
	local type_msg=''
	local re=''
	local -i r

	[[ -v cli_options["$lo_ref"] ]] && return $(_stderr_ret "Only one $msg_ref option allowed!")
	cli_options["$lo_ref"]=''

	[[ $# < 4 ]] && return 0

	v="$4"
	type_msg="$5"
	re="$6"
	nshift_ref=2
	r=1
	if [[ -z "$v" ]]; then
		_stderr "Error: Option $msg_ref $type_msg."
		nshift_ref=1
	elif [[ ! "$v" =~ $re ]]; then
		_stderr "Wrong option argument \"$v\" to $msg_ref!"
	else
		disk_params["$lo_ref"]="$v"
		r=0
	fi

	return $r
}

__check_valid_options()
{
	local -n valid_options_ref="$1"
	local o=''
	local -i r=0

	for o in "${!cli_options[@]}"; do
		if [[ ! -v valid_options_ref["$o"] ]]; then
			_stderr "Invalid '$command' option \"-${all_options["$o"]}|--$o\""
			(( r++ ))
		fi
	done

	return $r
}

_check_valid_attach_opts()
{
	# Only allowed options with 'attach-disk' command.
	local -Ar valid_options=(
		[host]=''
		[bus]=''
		[target]=''
		[lun]=''
		[io]=''
		[cache]=''
		[discard]=''
		[detect_zeroes]=''
		[logical_block_size]=''
		[physical_block_size]=''
		[shareable]=''
		[help]=''
		[verbose]=''
		[version]=''
	)

	__check_valid_options valid_options
}

_check_valid_detach_opts()
{
	# Only allowed options with 'detach-disk' command.
	local -Ar valid_options=(
		[host]=''
		[bus]=''
		[target]=''
		[lun]=''
		[io]=''
		[cache]=''
		[discard]=''
		[detect_zeroes]=''
		[logical_block_size]=''
		[physical_block_size]=''
		[all]=''
		[help]=''
		[verbose]=''
		[version]=''
	)

	__check_valid_options valid_options
}

_check_valid_list_opts()
{
	# Only allowed options with 'list' command.
	local -Ar valid_options=(
		[host]=''
		[bus]=''
		[target]=''
		[lun]=''
		[io]=''
		[cache]=''
		[discard]=''
		[detect_zeroes]=''
		[device_defaults]=''
		[logical_block_size]=''
		[physical_block_size]=''
		[quiet]=''
		[short]=''
		[noheading]=''
		[shareable]=''
		[help]=''
		[verbose]=''
		[version]=''
	)

	__check_valid_options valid_options
}

_is_min_512_po2()
{
	local -i n=$1

	(( n < 512 ))     && return 1
	(( n & (n - 1) )) && return 1
	return 0
}

_glob_expand_core()
{
	local prefix="$1"
	local pattern="$2"
	local any="$3"
	local c rest class from to
	local -i i j k from_pos to_pos

	if [[ -z $pattern ]]; then
		  printf '%s ' "$prefix"
		  return
	fi

	c="${pattern:0:1}"
	rest="${pattern:1}"

	case $c in
	'?')
		for (( i = 0; i < ${#any}; i++ )); do
			_glob_expand_core "$prefix${any:i:1}" "$rest" "$any"
		done
		;;
	 '[')
		# Locate the closing bracket
		for (( i = 1; i < ${#pattern}; i++ )); do
			[[ ${pattern:i:1} == ']' ]] && break
		done

		# Treat an unmatched '[' literally
		if (( i == ${#pattern} )); then
			_glob_expand_core "$prefix[" "$rest" "$any"
			return
		fi

		class="${pattern:1:i-1}"
		rest="${pattern:i+1}"

		# Process characters and ranges inside [...]
		for (( j = 0; j < ${#class}; j++ )); do
			if (( j + 2 < ${#class} )) && [[ ${class:j+1:1} == '-' ]]; then
				from="${class:j:1}"
				to="${class:j+2:1}"
				from_pos=-1
				to_pos=-1

				for (( k = 0; k < ${#any}; k++ )); do
					[[ "${any:k:1}" == "$from" ]] && from_pos=$k
					[[ "${any:k:1}" == "$to"  ]] && to_pos=$k
				done


				if ((from_pos >= 0 && to_pos >= from_pos)); then
					for (( k = from_pos; k <= to_pos; k++ )); do
						_glob_expand_core "$prefix${any:k:1}" "$rest" "$any"
					done
				fi

				(( j += 2 ))
			else
				_glob_expand_core "$prefix${class:j:1}" "$rest" "$any"
			fi
		done
		;;

	*)
		_glob_expand_core "$prefix$c" "$rest" "$any"
		;;
	esac
}

# Ensure minimum character set for glob expansion.
_glob_expand()
{
	local pattern="$1"
	local any="${2:-abcdefghijklmnopqrstuvwxyz}"

	_glob_expand_core '' "$pattern" "$any"
}

# Expand globs containing wildcard character '?' and ranges '[a-z]' on all @args device arguments
#
# E.g. 'sd[a-cf-h]' to 'sda adb adc sdf sdg sdh'
# -or-
# 'sd?' to 'sda sdb sdc ... sdz'
#
_glob_expand_devices()
{
	local dev=''
	local -a devices_tmp=()

	for dev in "${args[@]}"; do
		if [[ "$dev" =~ ^/dev/ ]]; then
			devices_tmp+=( "$(_glob_expand "$dev" 'abcdefghijklmnopqrstuvwxyz0123456789')" )
		else
			devices_tmp+=( "$(_glob_expand "$dev" '')" )
		fi
	done

	args=( ${devices_tmp[@]} )
}

# Check bdev for paths and associative array entry for sd*.
_check_devices_in_args()
{
	local dev=''
	local -i err_devs=0
	local -a devices_tmp=()

	for dev in "${args[@]}"; do
		if [[ "$dev" =~ ^/dev/ ]]; then
			if [[ ! -b "$dev" ]]; then
				_stderr "Device \"$dev\" doesn't exist!"
				continue
			fi
		else
			if [[ ! -v dev_by_sd["$dev"] ]]; then
				if [[ "$dev" == "$domain" ]]; then
					_stderr "Device \"$dev\" and domain are the same. Is environment variable 'vm' set?"
				elif [[ ! "$dev" =~ ^sd[a-z] ]]; then
					_stderr "Device \"$dev\" has inproper name."
				else
					(( err_devs++ ))
				fi

				continue
			fi
		fi

		devices_tmp+=( "$dev" )
	done

	(( err_devs )) && _stderr "$err_devs (glob) requested devices not attached!"

	args=( ${devices_tmp[@]} )
}

# Check if all devices exist.
_check_devices()
{
	local dev=''
	local g=''
	local property=''

	_stdout_verbose "Checking list of devices applying any glob expansion."

	if (( "$command" != "list" && ! ${#args[@]} )); then
		_stdout_no_lf ""
		[[ -v cli_options[all] ]] || echo -n "Error: "
		 "No scsi block devices" >&2
		[[ -v cli_options[all] ]] && echo -n " attached"
		echo "!"
		return 1
	fi


	_glob_expand_devices
	_check_devices_in_args

	# args containing devices to process.
	if (( ${#args[@]} )); then
		return 0
	else
		[[ "$command" == "list" ]]        && return $(_stderr_ret "No devices attached.")
		[[ "$command" == "attach-disk" ]] && return $(_stderr_ret "No device(s) given to attach!")
	fi
}

# Function for 'detach-disk --all' command.
get_domblklist()
{
	local sd=''

	_stdout_verbose "Reporting \"$domain\" domblklist."

	for sd in "${!dev_by_sd[@]}"; do
		echo " $sd ${dev_by_sd[$sd]}"
	done
}

# Function only for 'detach-disk --all' command.
_populate_devices()
{
	local l=''
	local re="^[[:space:]]*sd[a-z]"
	local -A devices_tmp=()

	_stdout_verbose "Populating scsi block devices list of domain \"$domain\" to detach."

	while read -r l; do
		[[ "$l" =~ $re ]] && (( devices_tmp["${l##* }"]++ ))
	done < <(get_domblklist)

	# Collapse entries (e.g. /dev/X multiple times).
	args=("${!devices_tmp[@]}")
}


# Function only for 'attach-disk' command.
_get_next_free_scsi_lun()
{
	local dev="$1"
	local -n lun_ref="$2"
	local -i unused=0
	local l=''
	local property=''
	local sd=''
	local -A used_luns=()

	for property in "${!scsi_devices[@]}"; do
		[[ "$property" != *:lun ]] && continue
		sd="${property%%:*}"
		[[ ${scsi_devices["${sd}:host"]} == ${disk_params[host]} && \
		   ${scsi_devices["${sd}:bus"]} == ${disk_params[bus]} && \
		   ${scsi_devices["${sd}:target"]} == ${disk_params[target]} ]] && used_luns["${scsi_devices["${sd}:lun"]}"]=1
	done

	while (( lun_ref < ${device_limits[lun]} )); do
		[[ ! -v used_luns[$lun_ref] ]] && return 0
		(( lun_ref++ ))
	done

	return 1
}

# Define sd name (sd[a-z], sd[a-z][a-z], ...).
_define_sd_name()
{
	local -i n=$1
	local -n sd1_ref="$2"
	local alphabet="abcdefghijklmnopqrstuvwxyz"
	local suffix=

	while (( n >= 0 )); do
		suffix=${alphabet:n%26:1}$suffix
		(( n = n / 26 - 1 ))
	done

	sd1_ref="sd$suffix"
}

_define_next_free_sd_name()
{
	local -n sd_ref="$1"
	local dev="$2"
	local -i n=0

	while :; do
		_define_sd_name $n sd_ref
		if [[ ! -v dev_by_sd["$sd_ref"] ]]; then
			dev_by_sd["$sd_ref"]="$dev"
			return 0
		fi
		(( n++ ))
	done

	return 1
}



# $1 = name of caller's variable holding the device path or sd-name (in/out)
# $2 = name of caller's variable to receive the resolved sd-name (out)
_get_sd_from_device()
{
	local -n dev_ref="$1"
	local -n sd_ref="$2"
	local l=''
	local sd1=''
	local target=''
	local path=''

	[[ "$dev_ref" =~ ^[a-zA-Z0-9/_.-]+$ ]] || return 1 # Safety 1st...

	if [[ "$dev_ref" =~ ^/dev/ ]]; then
		for sd1 in "${!dev_by_sd[@]}"; do
			if [[ "$dev_ref" == "${dev_by_sd["$sd1"]}" ]]; then
				sd_ref="$sd1"
				return 0
			fi
		done

	elif [[ "$dev_ref" =~ ^sd[a-z]* ]]; then
		for sd1 in "${!dev_by_sd[@]}"; do
			if [[ "$sd1" == "$dev_ref" ]]; then
				sd_ref="$sd1"
				dev_ref="${dev_by_sd["$sd1"]}"
				return 0
			fi
		done
	fi

	return 1
}

_print_dev_properties()
{
	local sd="$1"

	echo "${dev_by_sd[$sd]}[$sd:${scsi_devices[$sd:host]}:${scsi_devices[$sd:bus]}:${scsi_devices[$sd:target]}:${scsi_devices[$sd:lun]}]"
}

# Add @sd, @dev, @lun, ... to dev_by_sd global associative array.
_add_device_to_arrays()
{
	local sd="$1"
	local dev="$2"
	local lun="$3"
	local property=''

	dev_by_sd["$sd"]="$dev"
	scsi_devices["$sd:lun"]="$lun"
	shift 3

	if (( $# > ${#disk_params_names[@]} - 2 )); then
		for property in "${disk_params_names[@]}"; do
			if [[ "$property" != "lun" ]]; then
				scsi_devices["${sd}:$property"]="$1"
				shift
			fi
		done
	else
		for property in "${disk_params_names[@]}"; do
			[[ "$property" == "lun" ]] || scsi_devices["${sd}:$property"]="${disk_params["$property"]}"
		done
	fi
}

_delete_device_from_arrays()
{
	local sd="$1"
	local dev="$2"

	unset dev_by_sd["$sd"]

	for property in ${disk_params_names[@]}; do
		unset scsi_devices["${sd}:$property"]
	done
}

_sds_report_sorted()
{
	local -n o_sort_ref="$1"
	local -n o_ref="$2"
	local sd=''
	local sds="${!o_sort_ref[@]}"
	local sds_sort=''
	local sds_sort_total=''
	local -i len=3
	local -i max_len=0
	local -i n=0

	for sd in $sds; do
		(( max_len < ${#sd} )) && max_len=${#sd}
	done

	for (( len=3; len <= max_len; len++ )); do
		sds_sort=''

		for sd in $sds; do
			if [[ ${#sd} == $len ]]; then
				sds_sort+="$sd"$'\n'
				(( n++ ))
			fi
		done

		sds_sort_total+="$(echo "$sds_sort" | sort -n)"
	done

	(( n )) || return 1

	for sd in $sds_sort_total; do
		o_ref+="${o_sort_ref["$sd"]}"$'\n'
	done

	echo "$o_ref" | $column_cmd -t
	return 0
}

_cli_option_equals_disk_params()
{
	local sd="$1"
	local property="$2"
	local params="${disk_params[$property]}"
	local p=''

	# Can be comma seperated list, e.g. via "--target 11,48"
	params="${params//,/ }"

	for p in $params; do
		[[ "$p" == "${scsi_devices["$sd:$property"]}" ]] && return 0
	done

	return 1
}

_filter_disk_params_set()
{
	local sd="$1"
	local property=''

	for property in "${disk_params_names[@]}";do
		[[ -v cli_options["$property"] ]] && return 0
	done

	return 1
}

_filter_by_disk_params()
{
	local sd="$1"
	local property=''

	for property in "${disk_params_names[@]}";do
		[[ ! -v cli_options["$property"] ]] && continue
		_cli_option_equals_disk_params "$sd" "$property"
		[[ $? == 0 ]] || return 1
	done

	return 0
}

_check_dev()
{
	local -n devs_ref="$1"
	local dev="$2"
	local sd="$3"

	(( ${#devs[@]} )) || return 0
	[[ -v devs_ref["$dev"] ]] && return 0
	[[ -v devs_ref["$sd"] ]] && return 0
	return 1
}

_list_attached_devices()
{
	local -i report_type=$1
	local property=''
	local sd=''
	local sds=''
	local dev=''
	local o=''
	local -A o_sort=()
	local -i len=0
	local -A devs=()
	local -A widths=()

	(( ${#scsi_devices[@]} )) || return 0

	# Populate devices associative array.
	for dev in "${args[@]}"; do
		devs["$dev"]=""
	done

	# Adjust/avoid header.
	if [[ ! -v cli_options[quiet] && ! -v cli_options[noheading] ]]; then
		case $report_type in
		0)
			o=''
			;;
		1)
			o="$(echo -e "TARGET PATH")"$'\n'
			;;
		2)
			o="$(echo -e "TARGET PATH H:B:T:L LBS:PBS CACHE IO DISCARD DETECTZ SHARABLE")"$'\n'
			;;
		*)
			return $(_stderr_ret "Fatal: ${FUNCNAME[0]} called with bogus report_type $report_type!")
		esac
	fi

	for sd in ${!dev_by_sd[@]}; do
		dev="${dev_by_sd["$sd"]}"
		_check_dev devs $dev $sd || continue
		_filter_by_disk_params "$sd" || continue

		case $report_type in
		2|1)
			o_sort["$sd"]="$sd $dev"
			(( report_type == 1 )) && continue

			o_sort["$sd"]+=" ${scsi_devices["${sd}:host"]}:${scsi_devices["${sd}:bus"]}:${scsi_devices["${sd}:target"]}:${scsi_devices["${sd}:lun"]} ${scsi_devices["${sd}:logical_block_size"]}:${scsi_devices["${sd}:physical_block_size"]} ${scsi_devices["${sd}:cache"]} ${scsi_devices["${sd}:io"]} ${scsi_devices["${sd}:discard"]} ${scsi_devices["${sd}:detect_zeroes"]} ${scsi_devices["${sd}:shareable"]}"
			;;
		0)
			o_sort["$sd"]="$sd"
			;;
		*)
			return $(_stderr_ret "Fatal: Bogus report_type!")
			;;
		esac
	done

	if [[ -v cli_options[quiet] ]]; then
		(( ${#o_sort[@]} > 0 )) && return 0 || return 1
	elif (( ! report_type )); then
		o="${!o_sort[@]}"
		o="${o// /$'\n'}"
		o="$o"$'\n'
		printf "%s" "$o"
		return 0
	fi

	_sds_report_sorted o_sort o
}

# Parse the help output defining associative options array entries for each of the options.
define_options()
{
	local l=''
	local so=''
	local lo=''

	# Parse short and long option identifiers and define hash array elements accordingly.
	while IFS= read -r l; do
		if [[ "$l" =~ ^\ +\[-[a-zA-Z]\| ]]; then
			so="${l#*\[-}"
			lo="$so"
			so="${so%\|--*}"
			lo="${lo#*--}"
			lo="${lo%%[ \]]*}"
			all_options["$lo"]="$so"
		fi
	done < <(help)
}

# Split short option sets up for individual parse_cli processing, e.g. "-Vh" -> "-V -h"
_split_short_options()
{
	local -n args_ref1="$1"
	local -a args_tmp=()
	local -i a=0
	local -i i
	local -i len
	local o

	while (( a < ${#args_ref1[@]} )); do
		o="${args_ref1[$a]}"
		len=${#o}
		if [[ "$o" =~ ^-[a-zA-Z]+ ]]; then
			i=1
			while (( i < len )); do
				args_tmp+=( "-${o:$i:1}" )
				(( i++ ))
			done
		else
			args_tmp+=( "$o" )
		fi
		(( a++ ))
	done

	args_ref1=( "${args_tmp[@]}" )
	return 0
}

# Parse CLI command, options and their argumentsi (I like this better than getopts).
parse_cli()
{
	local -n args_ref="$1"
	local -i a=0
	local -i r=0
	local -i nshift=0
	local a2=''
	local lo=''
	local opt=''
	local re=''

	_split_short_options args_ref
	cli_options[verbose]=0

	# --- Parse options and (their) arguments ---
	for (( a=0; ! r && a < ${#args_ref[@]}; a+=nshift )); do
		nshift=1
		a2="${args_ref[((a+1))]}"

		if is_option "${args_ref[$a]}" lo; then
			opt="-${all_options["$lo"]}|--$lo"

			case "$lo" in
			all|device_defaults|help|noheading|quiet|short|version)
				_check_option lo opt nshift || r=1 # Shorter list -> only check and set option
				;;
			host|bus|target|lun)
				_check_option lo opt nshift "$a2" "requires one or more, comma seperated >= 0 integers" '^[][0123456789,-?]+$' || r=1
				;;
			cache|detect_zeroes|discard|io)
				_check_option lo opt nshift "$a2" "requires one or more, comma seperated mode arguments" '^[a-z,]+$' || r=1
				;;
			logical_block_size|physical_block_size)
				_check_option lo opt nshift "$a2" "requires one or more, comma seperated >= 512 power-of-two integer" '^[0-9,]{3,}$' || r=1
				;;
			shareable)
				_check_option lo opt nshift "$a2" "requires yes|no" '^[a-z,]+$' || r=1
				;;
			verbose)
				(( cli_options["$lo"]++ ))
				;;
			esac
		else
			if [[ "${args_ref[$a]:0:1}" == "-" ]]; then
				_stderr "Unknown option: ${args_ref[$a]}"
				r=1
			else
				# Save any non-option arguments for device name/path processing.
				args+=( "${args_ref[$a]}" )
			fi
		fi
	done

	_stdout_verbose "Parsed command line."

	(( r )) && cli_options[help]=''

	return $r
}

is_root()
{
	_stdout_verbose "Checking we run on root."
	[[ $EUID -eq 0 ]] && return 0
	return $(_stderr_ret "must be run as root!")
}

# Check for external command prerequisites and define shell variables with their full paths for callout safety.
check_prereq_tools()
{
	local -a prereqs=("/usr/bin/column" "/usr/bin/flock" "/usr/bin/sort" "/usr/bin/virsh")
	local prereq=''

	_stdout_verbose "Checking tool prerequisites."

	for prereq in "${prereqs[@]}"; do
		(( ${cli_options[verbose]} > 1 )) && _stdout_verbose "Checking tool $prereq"
		[[ ! -x $prereq ]] && return $(_stderr_ret "Mandatory $prereq command missing!")

		# Define tool variables with full paths for safety.
		eval "${prereq##*/}"_cmd="$prereq"
	done

	return 0
}

_adjust_command()
{
	local -n cmd_ref="$1"
	local c=''
	local -a commands1=("attach-disk" "detach-disk" "list")

	for c in "${commands1[@]}"; do
		if [[ "$cmd_ref" == "${c:0:${#cmd_ref}}" ]]; then
			cmd_ref="$c"
			return 0
		fi
	done

	return 1
}

_adjust_option_arguments()
{
	local option=''
	local optargs=''
	local arg=''
	local arg_alias=''
	local param=''
	local params=''
	local params_all=''
	local -i len_arg=0
	local -i len_alias=0
	local -i len_param=0
	local -i r=0

	for option in ${!option_arg_ranges[@]}; do
		optargs="${option_arg_ranges["$option"]}"
		[[ "${optargs:0:1}" =~ [0-9] ]] && continue
		optargs="${optargs//|/ }"
		params="${disk_params["$option"]}"
		params="${params//,/ }"
		params_all=''
		for param in $params; do
			len_param=${#param}

			for arg in $optargs; do
				arg_alias="$arg"
				# Identify option argument alias split by ':' (see writeback:wb in option_arg_ranges associative array)
				arg_alias="${arg_alias#*:}"
				arg="${arg%%:*}"
				len_arg=${#arg}
				len_alias=${#arg_alias}

				r=1
				if [[ "$param" == "${arg:0:$len_param}" ||
				      "$param" == "${arg_alias:0:$len_alias}" ]]; then
					params_all+="$arg "
					r=0
					break
				fi
			done
		done

		if (( r )); then
			_stderr "Bogus --$option argument \"$param\"!"
		else
			params_all="${params_all% }"
			params_all="${params_all// /,}"
			disk_params["$option"]="$params_all"
		fi
	done

	(( r )) && return 1

	return 0
}

# Handle globs in ids removing leading zeroes from numbers.
_hbtl_handle_globs()
{
	local param=''
	local s=''
	local hbtl=''
	local hbtl_all=''

	for param in ${hbtl_params[@]}; do
		hbtl_all=''
		hbtl="${disk_params["$param"]}"
		hbtl="${hbtl//,/ }"
		for s in $hbtl; do
			hbtl_all+="$(_glob_expand "$s" '0123456789')"
		done
		hbtl_all="${hbtl_all%% }"
		hbtl="$hbtl_all"
		hbtl_all=''
		for s in $hbtl; do
			# Remove leading zeroes, but leave one zero for an all-zero value.
			while [[ ${#s} > 1 && "$s" =~ ^0 ]]; do
				s="${s#0}"
			done
			hbtl_all+="$s "
		done
		hbtl_all="${hbtl_all%% }"
		hbtl_all="${hbtl_all// /,}"
		disk_params["$param"]="$hbtl_all"
	done
}

# Check command line arguments' correctness.
check_cli()
{
	local -i nshift
	local -i r=0

	_stdout_verbose "Checking command options and arguments."

	if [[ -v cli_options[version] ]]; then
		_stdout "Version $version"
		r=1
	fi
	if [[ -v cli_options[help] ]]; then
		help
		r=1
	fi
	if [[ -v cli_options["device_defaults"] ]]; then
		_list_device_defaults
		r=1
	fi

	(( r )) && exit 0

	# Conditionally use 'vm' environment varible to define the domain and avoid it on the command line.
	command="${args[0]}"
	if [[ -v vm ]]; then
		_stdout_verbose "Using environment variable 'vm' to define the domain."
		domain="$vm"
		nshift=1
	else
		_stdout_verbose "Using command line supplied domain name."
		domain="${args[1]}"
		nshift=2
	fi

	args=("${args[@]:$nshift}") # Pop respective elements off the beginning, the rest should be valid devices!

	_adjust_command command
	(( $? )) && return $(_stderr_ret "Unsupported \"$command\" command!")

	_adjust_option_arguments
	(( $? )) && return $(_stderr_ret "Unsupported \"$command\" option arguments!")


	# Handle globs in ids removing leading zeroes from numbers.
	_hbtl_handle_globs

	if [[ "$command" =~ (attach-disk|detach-disk) ]]; then
		if [[ "$command" == "attach-disk" ]]; then
			(( ! ${#args[@]} )) && return $(_stderr_ret "Devices needed to attach")
			_check_valid_attach_opts
		else
			_check_valid_detach_opts
		fi

		if (( $? )); then
			_stderr_no_lf "Invalid '"$command"' option"
			(( r > 1 )) && echo -n "s" >&2
			echo "" >&2
			return 1
		fi

		# for param in "${hbtl_params[@]}"; do
			# [[ ! "${disk_params["$param"]}" =~ ^[0-9]+$ ]] && return $(_stderr_ret "Invalid '"$command"' $param option argument!")
		# done
	else
		_check_valid_list_opts || return 1
	fi

	[[ "$command" == list && -v cli_options[quiet] && -v cli_options[short] ]] && \
		return $(_stderr_ret  "List options --quiet and --short are mutually exclussive!")

	# Sanity check on cache/io combination.
	# unsupported configuration: io=\'native\' needs either no disk cache or directsync c^
	if [[ "${disk_params[cache]}" != "none" && "${disk_params[cache]}" != "directsync" && "${disk_params[io]}" == "native" ]]; then
		_stderr "If cache mode isn't \"none\" or \"directsync\", io mode can't be 'native'!"
		r=1
	fi

	# Sanity check on detect zeroes and discard settings.
	if [[ "${disk_params[detect_zeroes]}" == "unmap" && "${disk_params[discard]}" != "unmap" ]]; then
		_stderr "If detect_zeroes is \"unmap\", discard needs to also be \"unmap\" to enable it!"
		r=1
	fi

	# Sanity check on logical and physical block sizes.
	if [[ "$command" != "list" ]]  && (( ${disk_params[logical_block_size]} > ${disk_params[physical_block_size]} )); then
		if [[ -v cli_options[physical_block_size] ]]; then
			_stderr "Logical block size larger physical block size not supported!"
			r=1
		else
			(( ${cli_options[verbose]} )) && \
				_stdout "Physical block size ${disk_params[physical_block_size]} smaller than logical block size ${disk_params[logical_block_size]}, raising..."
			disk_params[physical_block_size]="${disk_params[logical_block_size]}"
		fi
	fi

	if ! _is_min_512_po2 "${disk_params[logical_block_size]}"; then
		_stderr "Logical block size has to be power of 2 >= 512!"
		r=1
	fi

	if ! _is_min_512_po2 "${disk_params[physical_block_size]}"; then
		_stderr "Physical block size has to be power of 2 >= 512!"
		r=1
	fi

	if [[ -v cli_options[all] && ${#args[@]} -ne 0 ]]; then
		_stderr "No further scsi device arguments with 'detach-disk --all'!"
		r=1
	fi

	return $r
}

# Lock against parallel invocations.
lock_run()
{
	_stdout_verbose "Locking against parallel invocations."

	# Use lockfile to prevent parallel invocations.
	local lock_file="/run/lock/$cmd-$UID.lock"

	trap "rm -f $lock_file $tmpf_disk_xml 2>/dev/null" EXIT
	exec 9>"$lock_file" || return $(_stderr_ret  "Cannot open lock file \"$lock_file\"")
	$flock_cmd -n 9 || return $(_stderr_ret  "Already running!")
	return 0
}

_list_device_defaults()
{
	local param=''
	local o=''

	[[ -v cli_options[device_defaults] ]] || return 0
	(( ${#disk_params_names[@]} == ${#disk_params[@]} )) || _stderr "Internal: device defaults mismatch!"
	[[ -v cli_options[noheading] ]] || o='PARAMETER VALUE RANGE'$'\n'

	for param in ${disk_params_names[@]}; do
		o+=$(echo -e "$param ${disk_params_defaults[$param]}")
		[[ -v option_arg_ranges["$param"] ]] && o+=$(echo -e " ${option_arg_ranges["$param"]}")$'\n'
		o+=$'\n'
	done

	echo -e "$o" | $column_cmd -t
}

# Function to retrieve all needed domain configuration information.
parse_domain_config()
{
	local host=''
	local bus=''
	local target=''
	local lun=''
	local sd=''
	local l=''
	local shareable=''
	local -i disk=0

	_stdout_verbose "Parsing \"$domain\" virtual machine configuration from xml dump."

	while IFS= read -r l; do
		if (( ! disk )); then
			if [[ "$l" =~ ^[[:space:]]*\<disk[[:space:]]+ ]]; then
				disk=1
				shareable="no"
			fi
		else
			if [[ "$l" =~ ^[[:space:]]*\<source[[:space:]]+dev ]] && disk=1; then
				dev="$l"
				dev="${dev#*\'}"
				dev="${dev%%\'*}"

			elif [[ "$l" =~ \<target[[:space:]]+dev=\' ]]; then
				#      <target dev='sda' bus='scsi'/>
				sd="${l#*\<target[[:space:]]*dev=\'}"
				sd="${sd%%\'*}"
				[[ $sd =~ ^sd ]] || disk=0

			elif [[ "$l" =~ logical_block_size ]]; then
				#      <blockio logical_block_size='1024' physical_block_size='4096'/>
					lbs="${l#*logical_block_size=\'}"
				pbs="$lbs"
				lbs="${lbs%%\'[[:space:]]*}"
				pbs="${pbs#*physical_block_size=\'}"
				pbs="${pbs%%\'*}"

			elif [[ "$l" =~ cache= ]]; then
				#      <driver name='qemu' type='raw' cache='none' io='threads' discard='ignore' detect_zeroes='off'/>
				cache="${l#*cache=\'}"
				io="$cache"
				cache="${cache%%\'*}"
				io="${io#*io=\'}"
				discard="$io"
				io="${io%%\'*}"
				discard="${discard#*discard=\'}"
				detect_zeroes="$discard"
				discard="${discard%%\'*}"
				detect_zeroes="${detect_zeroes#*detect_zeroes=\'}"
				detect_zeroes="${detect_zeroes%%\'*}"

			elif [[ "$l" =~ [[:space:]]+\<shareable/\> ]];  then
					shareable="yes"

			# <address type='drive' controller='1' bus='0' target='2' unit='4711'/>
			elif [[ "$l" =~ \<address[[:space:]]+type=\'drive\' ]]; then
				host="$l"
				host="${host#*controller=\'}"
				bus="$host"
				host="${host%%\'*}"
				bus="${bus#*bus=\'}"
				target="$bus"
				bus="${bus%%\'*}"
				lun="$target"
				target="${target#*target=\'}"
				lun="$target"
				target="${target%%\'*}"
				lun="${lun#*unit=\'}"
				lun="${lun%%\'*}"

				# Add config entries to associative scsi_devices array.
				_add_device_to_arrays $sd $dev $lun $host $bus $target $lbs $pbs $cache $io $discard $detect_zeroes $shareable

				disk=0
			fi
		fi
	done < <($virsh_cmd dumpxml "$domain" 2>/dev/null)
}

is_domain_active()
{
	local command1=''
	local o=''

	_stdout_verbose "Checking if \"$domain\" is active."
	[[ -z "$domain" ]] && return $(_stderr_ret "Domain is not defined!")

	o="$($virsh_cmd domstate "$domain" 2>&1)"
	if (( ! $? )); then
		[[ "$o" =~ running ]] && return 0
		_stderr "Domain \"$domain\" not active."
		command1="$domain"
		_adjust_command command1
		(( ! $? )) && _stderr "It seems to be a command typo!"
		command="$command"
		return 1
	fi
}

list_attached_devices()
{
	local -i report_type=2

	[[ "$command" == "list" ]] || return 0

	_stdout_verbose "Listing devices respecting report type."

	[[ -v cli_options[quiet] ]] && report_type=0
	[[ -v cli_options[short] ]] && report_type=1
	_list_attached_devices $report_type
	if (( $? )); then
		if [[ ! -v cli_options[quiet] ]]; then
			_stdout_no_lf "No "
			(( ${#args[@]} )) && echo -n "such filtered "
			echo -n "virtio-scsi device(s) attached to \"$domain\""
			[[ -v cli_options[host] || -v cli_options[bus] || -v cli_options[target] || -v cli_options[lun] ]] && \
			echo -n " on [${disk_params[host]}:${disk_params[bus]}:${disk_params[target]}:${disk_params[lun]}]"
			echo ""
		fi

		return 1 # Error on no Devices.
	fi

	exit 0 # List needs to exit success in case of devices.
}

define_check_devices()
{
	_stdout_verbose "Conditonally providing list of attached devices if none provided."
	if (( ! ${#args[@]} )); then
		_stdout_verbose "Populating list of attached devices conditionally."
		if [[ "$command" == "detach-disk" ]]; then
			[[ -v cli_options[all] ]] && _populate_devices
			_filter_disk_params_set && _populate_devices
		fi
		[[ "$command" == "list" && _filter_disk_params_set ]] && _populate_devices
	fi

	_check_devices
}

_check_limit()
{
	local limit="$1"
	local dev="$2"

	if (( disk_params["$limit"] > device_limits["$limit"] )); then
		_stderr_ret "scsi $limit ${disk_params["$limit"]} too large for \"$dev\" (max:${device_limits["$limit"]})!"
		return 1
	fi
}

# Attach a single scsi device.
_attach_device()
{
	local dev=''
	local sd=''
	local -i lun=0
	local -i r=0
	local limit=''
	local op=''
	local xml=''

	[[ $# != 3 || "$command" != "attach-disk" ]] && return 1
	dev="$1"
	sd="$2"
	lun=$3
	disk_params[lun]=$lun

	for limit in "${!device_limits[@]}"; do
		_check_limit "$limit" "$dev"
		r+=$?
	done

	(( r )) && return $r

	xml="$(_create_disk_xml $dev $sd $lun)"
	_stdout_verbose_no_lf "Attaching \"$dev\" -> \"$sd\" target"
	(( ${cli_options[verbose]} )) && echo ""
	echo "$xml" > "$tmpf_disk_xml"
	_stdout_verbose "Running: $virsh_cmd attach-device "$domain" "$tmpf_disk_xml""
	(( cli_options[verbose] > 1 )) && echo -ne " with libvirt domain xml:\n$xml\n"
	op="$($virsh_cmd attach-device "$domain" $tmpf_disk_xml 2>&1)"
	if (( $? )); then
		_stderr_no_lf "Failed to attach \"$dev\"!"
		if [[ "$op" =~ ^.*$'\n'.*write.*lock ]]; then
			echo -n " Trying to attach unshared device" >&2
			[[ ! -v cli_options[shareable] ]] && echo -n " without --shareable" >&2
			echo -n "?"
		fi
		echo ""
		r=1
	else
		_add_device_to_arrays $sd $dev $lun
		_stderr "$op: $(_print_dev_properties $sd)"
	fi

	return $r
}

# Detach a single scsi device.
_detach_device()
{
	local dev=''
	local sd=''
	local op=''
	local -i r=0

	[[ "$command" != "detach-disk" ]] && return 1
	(( $# != 2 )) && return 1

	dev="$1"
	sd="$2"

	if [[ -n "$sd" ]]; then
		_stdout_verbose "Detaching $dev -> $sd"
		_stdout_verbose "Running: $virsh_cmd "$command" "$domain" --target "$sd""
		op="$($virsh_cmd "$command" "$domain" --target "$sd" 2>&1)"
		if (( $? )); then
			return $(_stderr_ret "Failed to detach \"$dev\"")
		else
			_stdout "$op: $(_print_dev_properties $sd)"
			_delete_device_from_arrays "$sd" "$dev"
			r=$?
		fi
	else
		_stderr "Failed to identify scsi device for \"$dev\"!  Is it actually attached to domain \"$domain\"?"
		r=1
	fi

	return $r
}

# Either attach or detach a set of scsi devices.
attach_or_detach_devices()
{
	local dev=''
	local dev_sav=''
	local msg='attaching'
	local sd=''
	local -i lun="${disk_params[lun]}"
	local -i n=0
	local -i r=0

	[[ "$command" =~ (attach-disk|detach-disk) ]] || return 0

	[[ "$command" == "attach-disk" ]] && msg="Attaching to" || msg="Detaching from"
	_stdout_verbose "$msg \"$domain\""

	while (( ${#args[@]} )); do
		dev="${args[0]}"
		dev_sav="$dev"
		args=("${args[@]:1}") # Pop device off the arguments array.

		if [[ "$command" == "attach-disk" ]]; then
			_define_next_free_sd_name sd $dev
			_get_next_free_scsi_lun "$dev" lun
			(( $? )) && _stderr "Failed to get next free virtio-scsi lun for \"$dev\""
			_attach_device "$dev" "$sd" $lun || return 1
			(( n++ ))

		elif [[ "$command" == "detach-disk" ]]; then
			while _get_sd_from_device dev sd; do
				if (( $? )); then
					_stdout "Device \"$dev\" is not attached to \"$domain\"!"
					(( r++ ))
					continue
				fi

				if ! _filter_by_disk_params "$sd"; then
					_delete_device_from_arrays "$sd" "$dev"
					continue
				fi

				_detach_device "$dev" "$sd"  || return 1
				(( n++ ))
				dev="$dev_sav"
			done
		fi

		(( lun++ ))
	done

	if (( r )); then
		_stderr_no_lf "$r invalid device"
		(( r > 1 )) && echo -n "s" >&2
		echo " processed detaching!" >&2
		r=1
	elif (( ! n )); then
		[[ "$command" == "attach-disk" ]] && msg="attached" || msg="detached"
		printf "$cmd -- No devices %s." "$msg"
	fi

	return $r
}

#
# "Main"
#
declare -a args_copy=("$@") # Depp copy to index arguments in parse_cli()
define_options		 || exit 1
parse_cli args_copy      || exit 1
is_root                  || exit 1
check_prereq_tools       || exit 1
check_cli                || exit 1
lock_run                 || exit 1
is_domain_active         || exit 1
parse_domain_config      || exit 1
define_check_devices     || exit 1
list_attached_devices    || exit 1
attach_or_detach_devices || exit 1
