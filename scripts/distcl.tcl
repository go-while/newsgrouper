# DisTcl - Distributed Programming Infrastructure for Tcl

# DisTcl provides a communication channel between clients and named services.
# Each named service can process certain forms of request.  A service may be
# implemented by multiple server processes and used by multiple client
# processes.  All these processes may be on different machines.  Redis
# (or one of the compatible forks) is used to communicate between clients
# and servers, and to cache results.


# Details of operation:
#
# A request to service "abc" for key "def" will proceed as follows:
# The value may be requested by writing def to redis queue q:abc .
# A prefetch may be requested by writing def to redis queue p:abc .
#
# A server reads "def" from q:abc or p:abc, and pushes 0 (for a prefetch)
# or 1 (for a get) onto list r:abc:def. If this list already had an entry,
# this request is already being computed by another server so skip it, otherwise...
#
# The server computes value "ghi" with status s from key "def" .
# The server writes "s:ghi" to the Value cache v:abc:def .
# The server pushes "s:ghi" to the Waitlist w:abc:def as many times as there
# are get requests recorded in r:abc:def .
# Each client which requested the value for def reads it from queue w:abc:def .
# After this, any client which requests this value will read it from v:abc:def .
#
# Each server also monitors an individual control queue z:id through which
# it can be requested to shut down cleanly.

package require retcl

namespace eval distcl {

# Loop serving requests, will continue until told 'stop' via the control queue.
#
# redis - a retcl connection to redis, authenticated if necessary;
# service - name of the service being provided;
# proc - command to call to process the request and return its value.
# id - optional identifier for this service instance.
proc serve {redis service proc {id {}}} {
    set reqqueue q:$service
    set prequeue p:$service
    if {$id eq {}} {set id [pid]}
    set ctlqueue z:$id
    puts stderr "Control queue is '$ctlqueue'"
    set verbose 0

    while 1 {
        # wait for a request to appear on one of the queues
        set qreq [$redis -sync blpop $ctlqueue $reqqueue $prequeue 300]
        if {$qreq eq "(nil)"} {
            # keep things alive?
            continue
        }
        lassign $qreq queue request
        if {$verbose} {puts "QUEUE $queue REQUEST '$request'"}

        # server control request?
        if {$queue eq $ctlqueue} {
	    switch -glob -- $request {
	        stop break
	        v* {set verbose 1}
	        q* {set verbose 0}
	    }
            continue
	}

        # request is get or prefetch
        set is_get [expr {$queue eq $reqqueue}]
        set runlist r:${service}:$request
        set runcount [$redis -sync rpush $runlist $is_get]
        # is the same request already running on another server?
        if {$runcount > 1} continue
        $redis -sync expire $runlist 20

        # check if it's already cached
        set result [$redis -sync get v:${service}:$request]
        if {$result eq "(nil)"} {

            # call the request processor
            set status [catch {$proc {*}$request} value options]
            if {$status == 1} {set value [dict get $options -errorinfo]}
            set result ${status}:$value

            # cache the result if an expiry time was specified
	    if {[dict exists $options -secs2keep]} {
	        set expiry [dict get $options -secs2keep]
	        if {$expiry} {
                    $redis -sync set v:${service}:$request $result ex $expiry
                }
            }
            if {$verbose} {puts "COMPUTED: [string range $result 0 59]"}
        }

        # push the result to the waitlist for each client waiting
        set requests [$redis -sync lpop $runlist 999]
        if {$requests eq {(nil)}} {set requests {}}
        set waiters [tcl::mathop::+ {*}$requests]
        if {$waiters} {
            set waitlist w:${service}:$request
            while {$waiters} {
                $redis -sync rpush $waitlist $result
                incr waiters -1
            }
            $redis -sync expire $waitlist 10
        }
    }
}


# Request the data computed by service for these arguments.
#
# redis - a retcl connection to Redis, authenticated if necessary;
# service - name of the service to call;
# args - one or more arguments to pass to the service.
proc get {redis service args} {
    set key v:${service}:$args
    # try to read the data from the cache
    set res [$redis -sync get $key]
    if {$res eq "(nil)"} {
        # data not in cache, send a request for it
        $redis -sync rpush q:$service $args

        # wait for the data to be returned in the waitlist
        set qres [$redis -sync blpop w:${service}:$args 20]
        # if 20 second timeout expired, report error
        if {$qres eq "(nil)"} {error "Request for '$key' timed out."}
        set res [lindex $qres 1]
    }
    # parse the result and return it
    if {[string index $res 1] ne ":"} {error "Malformed result for '$key'."}
    set status [string index $res 0]
    set value [string range $res 2 end]
    return -code $status $value
}

# Request that a data item be precomputed as it will soon be needed.
# We don't wait for the reply, so multiple prefetches can be issued
# and processed in parallel if multiple servers are available.
#
# redis - a retcl connection to Redis, authenticated if necessary;
# service - name of the service to call;
# args - one or more arguments to pass to the service.
proc prefetch {redis service args} {
    set key v:${service}:$args
    # check if it's already cached
    if {! [$redis -sync exists $key]} {
        # not cached, send request to precompute it
        $redis -sync rpush p:$service $args
    }
}

# Remove a previously-computed data item from the cache.
#
# redis - a retcl connection to Redis, authenticated if necessary;
# service - name of the service;
# args - one or more arguments.
proc forget {redis service args} {
    set key v:${service}:$args
    # waitlist could be left behind by a crash, so delete it too
    set waitlist w:${service}:$args
    $redis -sync del $key $waitlist
}

# Set a data item in the cache, e.g. when found as a by-product of another computation.
#
# redis - a retcl connection to Redis, authenticated if necessary;
# service - name of the service;
# request - one or more arguments as a list;
# value - the value to store;
# expiry - length of time in seconds to keep this value.
proc save {redis service request value expiry} {
    $redis -sync set v:${service}:$request 0:$value ex $expiry
}

}
