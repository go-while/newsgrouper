# Utilities.

# a little debugging helper
proc printvars args {
    set now [clock microseconds]
    set elapsed [expr {$::printvars_time ? $now - $::printvars_time : 0}]
    set ::printvars_time $now
    puts -nonewline "[format %8d $elapsed] "
    
    foreach var $args {
        upvar $var pv[incr n]
	if {[info exists pv$n]} {
            puts -nonewline "$var='[set pv$n]' "
        } else {
            puts -nonewline "$var: "
        }
    }
    puts {}
}
set printvars_time 0

