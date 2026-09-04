Script to dynamically attach/detach host block as virtio-scsi devices ito qemu/kvm virtual machine and list their properties (e.g. for mass device testing).

Glob expansion for device paths and targets is supported.
virtio-scsi properties host, target, lun, logical_block_size, physical_block_size, io, cache, discard. detect_zeroes are fully configrable (bus limited to 0 for virtio-scsi).

Virtual machine has to be configured with at least one scsi controller.

See --help.


Example commands and output run as root:

# alias v=/usr/local/bin/vm_attach_or_detach_disks.sh

# v --help
Usage: vm_attach_or_detach_disks.sh [{attach-disk|detach-disk|list} <domain>] [path|target]...
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

Environment variable 'vm' can be used to define the default domain for the command.

# v --device_defaults   # : in range means paramater alias to use
PARAMETER            VALUE    RANGE
host                 0        0|1|2|3|...|253
bus                  0        0
target               0        0|1|...|255
lun                  0        0|1|...|16383
logical_block_size   512      512|1024|2048|...|32768
physical_block_size  512      512|1024|2048|...|2097152
cache                none     none|writeback:wb|writethrough:wt|directsync:ds|unsafe
io                   threads  native|threads
discard              unmap    ignore|unmap
detect_zeroes        unmap    off|on|unmap
shareable            yes      yes|n

# v attach-disk $domain /dev/ws/d0 /dev/sda --host 5 --target 7 --lun 47
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/ws/d0[sda:5:0:7:47]
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/sda[sdb:5:0:7:48]

# export vm="$domain"

# v list
TARGET  PATH        H:B:T:L   LBS:PBS  CACHE  IO       DISCARD  DETECTZ  SHARABLE
sda     /dev/ws/d0  5:0:7:47  512:512  none   threads  unmap    unmap    yes
sdb     /dev/sda    5:0:7:48  512:512  none   threads  unmap    unmap    yes

# v detach-disk /dev/sda
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/sda[sdb:5:0:7:48]

# v detach-disk /dev/ws/d0
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/ws/d0[sda:5:0:7:47]

# v l
vm_attach_or_detach_disks.sh -- No devices attached.

# v a /dev/iscsi/1P.[0-5] --cache unsafe
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/iscsi/1P.0[sda:0:0:0:0]
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/iscsi/1P.1[sdb:0:0:0:1]
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/iscsi/1P.2[sdc:0:0:0:2]
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/iscsi/1P.3[sdd:0:0:0:3]
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/iscsi/1P.4[sde:0:0:0:4]
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/iscsi/1P.5[sdf:0:0:0:5]

# v l
TARGET  PATH             H:B:T:L  LBS:PBS  CACHE   IO       DISCARD  DETECTZ  SHARABLE
sda     /dev/iscsi/1P.0  0:0:0:0  512:512  unsafe  threads  unmap    unmap    yes
sdb     /dev/iscsi/1P.1  0:0:0:1  512:512  unsafe  threads  unmap    unmap    yes
sdc     /dev/iscsi/1P.2  0:0:0:2  512:512  unsafe  threads  unmap    unmap    yes
sdd     /dev/iscsi/1P.3  0:0:0:3  512:512  unsafe  threads  unmap    unmap    yes
sde     /dev/iscsi/1P.4  0:0:0:4  512:512  unsafe  threads  unmap    unmap    yes
sdf     /dev/iscsi/1P.5  0:0:0:5  512:512  unsafe  threads  unmap    unmap    yes

# v a -C none /dev/iscsi/1P.[6-9]
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/iscsi/1P.6[sdg:0:0:0:6]
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/iscsi/1P.7[sdg:0:0:0:7]
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/iscsi/1P.8[sdg:0:0:0:8]
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/iscsi/1P.9[sdg:0:0:0:9]

# v l -C n
TARGET  PATH             H:B:T:L  LBS:PBS  CACHE  IO       DISCARD  DETECTZ  SHARABLE
sdg     /dev/iscsi/1P.6  0:0:0:6  512:512  none   threads  unmap    unmap    yes
sdh     /dev/iscsi/1P.7  0:0:0:7  512:512  none   threads  unmap    unmap    yes
sdi     /dev/iscsi/1P.8  0:0:0:8  512:512  none   threads  unmap    unmap    yes
sdj     /dev/iscsi/1P.9  0:0:0:9  512:512  none   threads  unmap    unmap    yes

# v l -C u
TARGET  PATH             H:B:T:L  LBS:PBS  CACHE   IO       DISCARD  DETECTZ  SHARABLE
sda     /dev/iscsi/1P.0  0:0:0:0  512:512  unsafe  threads  unmap    unmap    yes
sdb     /dev/iscsi/1P.1  0:0:0:1  512:512  unsafe  threads  unmap    unmap    yes
sdc     /dev/iscsi/1P.2  0:0:0:2  512:512  unsafe  threads  unmap    unmap    yes
sdd     /dev/iscsi/1P.3  0:0:0:3  512:512  unsafe  threads  unmap    unmap    yes
sde     /dev/iscsi/1P.4  0:0:0:4  512:512  unsafe  threads  unmap    unmap    yes
sdf     /dev/iscsi/1P.5  0:0:0:5  512:512  unsafe  threads  unmap    unmap    yes

# v -nL 5
sdf  /dev/iscsi/1P.5  0:0:0:5  512:512  unsafe  threads  unmap  unmap  yes

# v d -L 5
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/iscsi/1P.5[sdf:0:0:0:5]

# v a -H 1 -T 5 -L 333 --logical 4096 -p 8192 /dev/ws/d'[01]'
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/ws/d0[sdf:1:0:5:333]
vm_attach_or_detach_disks.sh -- Device attached successfully: /dev/ws/d1[sdk:1:0:5:334]

# v l -nl 4096
sdf  /dev/ws/d0  1:0:5:333  4096:8192  none  threads  unmap  unmap  yes
sdk  /dev/ws/d1  1:0:5:334  4096:8192  none  threads  unmap  unmap  yes

# v d 'sd[adk]'
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/iscsi/1P.0[sda:0:0:0:0]
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/iscsi/1P.3[sdd:0:0:0:3]
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/ws/d1[sdk:1:0:5:334]

# v d -p 8192
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/ws/d0[sdf:1:0:5:333]

# v l -ns
sdb  /dev/iscsi/1P.1
sdc  /dev/iscsi/1P.2
sde  /dev/iscsi/1P.4
sdg  /dev/iscsi/1P.6
sdh  /dev/iscsi/1P.7
sdi  /dev/iscsi/1P.8
sdj  /dev/iscsi/1P.9

# v d --all
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/iscsi/1P.9[sdj:0:0:0:9]
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/iscsi/1P.8[sdi:0:0:0:8]
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/iscsi/1P.2[sdc:0:0:0:2]
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/iscsi/1P.1[sdb:0:0:0:1]
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/iscsi/1P.7[sdh:0:0:0:7]
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/iscsi/1P.6[sdg:0:0:0:6]
vm_attach_or_detach_disks.sh -- Disk detached successfully: /dev/iscsi/1P.4[sde:0:0:0:4]
