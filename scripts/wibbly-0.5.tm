#!/usr/bin/env tclsh
# Wibbly - a wibbly wobbly web server - Colin Macleod, 2026.
#
# Derived from:
# Wibble - a pure-Tcl Web server.
# Code: https://chiselapp.com/user/andy/repository/wibble/timeline
# Discussion: http://wiki.tcl.tk/23626
# Copyright 2009-2014 Andy Goth.  mailto/andrew.m.goth/at/gmail/dot/com
# Available under the Tcl/Tk license.  http://tcl.tk/software/tcltk/license.html

package require Tcl 9
package require coroutine

# Define the wibbly namespace.
namespace eval ::wibbly {}

# Expand a template.  Lines in the template body starting with % are treated
# as code and executed.  All other lines become part of the result after
# variable and command substitution.
proc ::wibbly::template {body} {
    set script ""
    set pos 0
    foreach match [regexp -line -all -inline -indices {^%.*$} $body] {
        lassign $match from to
        set str [string range $body $pos [expr {$from - 1}]]
        if {$str ne ""} {
            append script "append # \[" [list subst $str] \]\n
        }
        append script [string range $body [expr {$from + 1}] $to]\n
        set pos [expr {$to + 2}]
    }
    set str [string range $body $pos end]
    if {$str ne ""} {
        append script "append # \[" [list subst $str] \]
    }
    uplevel 1 "set # {}; $script; set #"
}

# Flatten a request/response state dictionary into a form that's easier to log.
proc ::wibbly::dumpstate {data {prefix ""}} {
    if {![llength $data]} {
        return [list $prefix ""]
    }
    set result {}
    dict for {key val} $data {
        set key [concat $prefix [list $key]]
        if {$key in {header accept query}} {
            lappend result {*}[dumpstate $val $key]
        } elseif {[string length $val] > 512} {
            lappend result $key (len=[string length $val])
        } else {
            lappend result $key $val
        }
	if {$key eq "rawtime"} {
            lappend result time [clock format $val]
	}
    }
    return $result
}

# ========================= network input procedures ==========================

# Get a line of data from the current coroutine's socket.
proc ::wibbly::getline {} {
    set socket [namespace tail [info coroutine]]
    #coroutine::util gets_safety $socket 4096 line
    set caught [catch {coroutine::util gets $socket line}]
    if {$caught || ($line eq {} && [chan eof $socket])} {
        return -level [info level]
    }
    return $line
}

# Get a block of data from the current coroutine's socket.
proc ::wibbly::getblock {size} {
    set socket [namespace tail [info coroutine]]
    set chunk [coroutine::util read $socket $size]
    if {$chunk eq {} && [chan eof $socket]} {
        return -level [info level]
    }
    return $chunk
}

# ==================== conversion and parsing procedures ======================

# Encode for HTML by substituting angle brackets, ampersands, space sequences,
# and line breaks.
proc ::wibbly::enhtml {str} {
    string map {< &lt; > &gt; & &amp; \r "" \n "<br />\n" "  " \ &\#160;} $str
}

# Encode for HTML tag attribute by substituting angle brackets, ampersands,
# space sequences, and single and double quotes.
proc ::wibbly::enattr {str} {
    string map {< &lt; > &gt; & &amp; \r "" \n "" "  " \ &\#160;
                ' &apos; \" &quot;} $str
}

# Encode for HTML <pre> by substituting angle brackets and ampersands.
proc ::wibbly::enpre {str} {
    string map {< &lt; > &gt; & &amp; \r ""} $str
}

# Encode a query string.  The caller must prepend the question mark.
proc ::wibbly::enquery {args} {
    set query {}
    set encode {apply {{str} {string map { " " +}\
        [enhex $str {[^-^,./'|!$\w ]}]} ::wibbly}}
    foreach {key val} [concat {*}$args] {
        if {[dict exists $val ""]} {
            lappend query [{*}$encode $key]=[{*}$encode [dict get $val ""]]
        } else {
            lappend query [{*}$encode $key]
        }
    }
    join $query &
}

# Decode a query string into a list.  The caller must strip the question mark.
proc ::wibbly::dequery {str} {
    set query {}
    foreach elem [split $str &] {
        regexp {^([^=]*)(?:(=.*))?$} $elem _ key val
        if {$val ne ""} {
            set val [list "" [dehex [string map {+ " "}\
                [string range $val 1 end]]]]
        }
        lappend query [dehex [string map {+ " "} $key]] $val
    }
    return $query
}

# Encode by substituting most non-alphanumerics with hexadecimal codes.
proc ::wibbly::enhex {str {pattern {[^-^,./'=+|!$\w]}}} {
    set pos 0
    while {[regexp -indices -start $pos $pattern $str range]} {
        binary scan [string range $str {*}$range] H2 char
        set str [string replace $str {*}$range %$char]
        set pos [expr {[lindex $range 0] + 3}]
    }
    return $str
}

# Decode hexadecimal encoding.
proc ::wibbly::dehex {str} {
    subst -novariables -nocommands\
        [regsub -all {%([[:xdigit:]]{2})} [string map {\\ \\\\} $str] {\\u00\1}]
}

# Encode an HTTP time/date.
proc ::wibbly::entime {time} {
    switch [lindex $time 0] {
        abstime {set time [lindex $time 1]}
        reltime {set time [expr {[clock seconds] + [lindex $time 1]}]}
    }
    clock format $time -format "%a %d-%b-%Y %T %Z" -timezone :GMT
}

# Decode an HTTP time/date.
proc ::wibbly::detime {str} {
    list abstime [clock scan $str]
}

# Decode header list encoding.
proc ::wibbly::delist {separator str} {
    regexp -all -inline [dict get {
semicolon {(?:[^;"=]+=)?(?:[Ww]/)?"(?:[^\\"]|\\.)*"|\((?:[^\\()]|\\.)*\)|[^;]+}
comma     {(?:[^,"=]+=)?(?:[Ww]/)?"(?:[^\\"]|\\.)*"|\((?:[^\\()]|\\.)*\)|[^,]+}
semicomma {(?:[^;,"=]+=)?"(?:[^\\"]|\\.)*"|\((?:[^\\()]|\\.)*\)|[^;,]+}
space     {"(?:[^\\"]|\\.)*"|\((?:[^\\()]|\\.)*\)|[^"()\\\s]+}
    } $separator] $str
}

# Encode HTTP header quoting when appropriate.
proc ::wibbly::enquote {str} {
    if {$str eq "" || [regexp {[\0-\040\177\(\)<>@,;:\\"/\[\]\?={}]} $str]} {
        return \"[regsub -all {[\0-\010\012-\037\177"\\]} $str {\\&}]\"
    } else {
        return $str
    }
}

# Decode HTTP header quoting.
proc ::wibbly::dequote {str} {
    if {([string index $str 0] eq "\"" && [string index $str end] eq "\"")
     || ([string index $str 0] eq "(" && [string index $str end] eq ")")} {
        regsub -all {\\(.)} [string range $str 1 end-1] {\1}
    } else {
        return $str
    }
}

# Encode an HTTP entity tag.
proc ::wibbly::entag {tag} {
    lassign $tag type val
    switch $type {
    tag {return \"[regsub -all {[\0-\010\012-\037\177"\\]} $val {\\&}]\"}
    weaktag {return W/\"[regsub -all {[\0-\010\012-\037\177"\\]} $val {\\&}]\"}
    }
}

# Decode an HTTP entity tag.
proc ::wibbly::detag {str} {
    if {[string range $str 0 2] in {W/\" w/\"}} {
        list weaktag [dequote [string range $str 2 end]]
    } else {
        list tag [dequote $str]
    }
}

# Write HTTP headers dictionary to a string.
proc ::wibbly::headers2string {header} {
    set str ""
    dict for {key val} $header {
        if {![llength $val]} continue
        append str "$key: $val\n"
    }
    return $str
}

# Convert string to HTTP headers dictionary.
proc ::wibbly::string2headers {str} {
    set header {}
    foreach {_ key raw} [regexp -all -inline -expanded -lineanchor {
        ^( [^\s:]+ ) \s*:\s*
        ( (?: [^\n] | \n[ \t] )* )
    } $str] {
        set key [string tolower $key]
        set raw [string trim $raw]
        #set raw [dequote $raw]
        dict set header $key $raw
    }
    return $header
}

# Get one HTTP header from the request dict and decode it.
proc ::wibbly::deheader {request args} {
    set raw [dict getdef $request {*}$args {}]
    if {$raw eq {}} return

    set key [lindex $args end]
    set val {}
    switch $key {
        cookie {
            # Value is one or more cookie definitions.
            set common {}
            set cookie ""
            foreach elem [delist semicomma $raw] {
                regexp {\s*([^\s=]*)(?:\s*=(.*))?} $elem _ key2 val2
                set key2 [string tolower $key2]
                if {[string index $key2 0] eq "\$"} {
                    set key2 [string trim [string range $key2 1 end]]
                    if {$cookie eq ""} {
                        dict set common $key2 [dequote $val2]
                    } else {
                        dict set params $key2 [dequote $val2]
                    }
                } else {
                    if {$cookie ne ""} {
                        lappend val $cookie $params
                    }
                    set cookie [dehex $key2]
                    set params $common
                    dict set params "" [dehex $val2]
                }
            }
            if {$cookie ne ""} {
                lappend val $cookie $params
            }
        } cache-control - pragma {
            # Value has format "subkey1=subval1,subkey2=subval2,subkey3".
            foreach elem [delist comma $raw] {
                regexp {\s*([^\s=]+)(?:\s*(=.*))?} $elem _ key2 val2
                if {$val2 ne ""} {
                    set val2 [dequote [string trim [string range $val2 1 end]]]
                    if {$key eq "cache-control"&& $key2 in {private no-cache}} {
                        set val2 [delist comma $val2]
                    }
                    set val2 [list "" $val2]
                }
                lappend val [string tolower $key2] $val2
            }
        } connection - content-encoding - content-language - none-match -
        trailer - upgrade - vary - via {
            # Value has format "elem1,elem2".
            foreach elem [delist comma $raw] {
                lappend val [dequote [string trim $elem]]
            }
        } if-match - if-none-match {
            # Value has format "tag1,tag2".
            foreach elem [delist comma $raw] {
                lappend val [detag [string trim $elem]]
            }
        } warning {
            # Value has format "elem1.1 elem1.2 elem1.3,elem2.1 elem2.2".
            foreach elem [delist comma $raw] {
                set val2 {}
                foreach elem2 [delist space $elem] {
                    lappend val2 [dequote $elem2]
                }
                lappend val $val2
            }
        } accept - accept-charset - accept-encoding - accept-language -
        expect - te - transfer-encoding {
            # Value has format "elem1;subkey1=subval1;subkey2=subval2,elem2".
            foreach elem [delist comma $raw] {
                set params {}
                set subs [delist semicolon $elem]
                foreach sub [lrange $subs 1 end] {
                    regexp {\s*([^\s=]+)(?:\s*=\s*(.*?)\s*)?} $sub _ key2 val2
                    lappend params [string tolower $key2] [dequote $val2]
                }
                lappend val [string tolower [string trim [lindex $subs 0]]]
                lappend val $params
            }
        } content-disposition - content-type {
            # Value has format "elem;subkey1=subval1;subkey2=subval2".
            set elems [delist semicolon $raw]
            set val [list "" [string tolower [lindex $elems 0]]]
            foreach elem [lrange $elems 1 end] {
                regexp {\s*([^\s=]+)(?:\s*=\s*(.*?)\s*)?} $elem _ key2 val2
                lappend val [string tolower $key2] [dequote $val2]
            }
        } user-agent {
            # Value is a user-agent definition.
            foreach elem [delist space $raw] {
                if {[string index $elem 0] eq "("} {
                    lappend val ([dequote $elem])
                } else {
                    lappend val [dequote $elem]
                }
            }
        } date - expires - if-modified-since - if-unmodified-since -
        last-modified {
            # Value is an absolute time.
            set val [detime $raw]
        } if-range {
            # Value is an absolute time or an entity tag.
            if {[string index $raw end] eq "\""} {
                set val [detag $raw]
            } else {
                set val [detime $raw]
            }
        } default {
            # Value has format "elem".
            set val [dequote $raw]
        }
    }
    return $val
}

if 0 {
    # Process qvalues in accept* headers.
    foreach {header key} {accept type   accept-charset charset
    accept-encoding encoding   accept-language language   te transfercoding} {
        set preferences {}
        if {[dict exists $request header $header]} {
            set options {}
            dict for {option params} [dict get $request header $header] {
                if {![string is double -strict [dict getdef $params q {}]]} {
                    lappend options [list $option 1]
                } elseif {[dict get $params q] > 0} {
                    lappend options [list $option [dict get $params q]]
                }
            }
            foreach elem [lsort -index 1 -decreasing -real $options] {
                lappend preferences [lindex $elem 0]
            }
        }
        dict set request accept $key $preferences
    }
}

# ==================== http request processing ======================

# Get an HTTP request from a client.
proc ::wibbly::getrequest {port chan peerhost peerport} {
    # The HTTP header uses CR/LF line breaks.
    chan configure $chan -translation crlf

    # Receive and parse the first line.  Normalize the path.
    regexp {^\s*(\S*)\s+(\S*)\s+(\S*)} [getline] _ method uri protocol
    regexp {^([^?]*)(\?.*)?$} $uri _ path query
    regsub -all {(?:/|^)\.(?=/|$)} [dehex $path] / path
    while {[regsub {(?:/[^/]*/+|^[^/]*/+|^)\.\.(?=/|$)} $path "" path]} {}
    regsub -all {//+} /$path / path
    set protocol [string toupper $protocol]

    # Start building the request structure.
    set request [dict create socket $chan peerhost $peerhost peerport $peerport\
        port $port rawtime [clock seconds] timems [clock milliseconds]\
        method $method uri $uri path $path protocol $protocol header {}]

    # Parse the query string.
    if {$query ne ""} {
        set query [string range $query 1 end]
        dict set request rawquery $query
        dict set request query [dequery $query]
    }

    # Receive and parse the headers.
    while {[set line [getline]] ne ""} {
        append rawheader $line \n
    }
    dict set request header [string2headers $rawheader]

    # Get and parse the request body, if there is one.
    if {$method eq "POST"} {
        # Get the request body.
        set trans_enc [dict getdef $request header transfer-encoding {}]
        if {[string match *chunked* $trans_enc]} {
            # Receive chunked request body.
            set data ""
            while {[scan [getline] %x length] == 1 && $length > 0} {
                chan configure $chan -translation binary
                append data [getblock $length]
                chan configure $chan -translation crlf
            }
        } else {
            # Receive non-chunked request body.
            chan configure $chan -translation binary
            set data [getblock [dict get $request header content-length]]
            chan configure $chan -translation crlf
        }
        dict set request rawpost $data

        # Parse the request body for known content-types.
        set c_t [deheader $request header content-type]
        switch [dict getdef $c_t "" {}] {
        multipart/form-data {
            # Interpret multipart/form-data (required for file uploads).
            set data \r\n$data
            set sep \r\n--[dict get $c_t boundary]
            set beg [expr {[string first $sep $data] + 2}]
            set end [expr {[string first $sep $data $beg] - 1}]
            set post ""
            while {$beg < $end} {
                set beg [expr {[string first \n $data $beg] + 1}]
                set part [string range $data $beg $end]
                set split [string first \r\n\r\n $part]
                set val [string2headers [string map {\r ""}\
                    [string range $part 0 [expr {$split - 1}]]]]
                dict set val "" [string range $part [expr {$split + 4}] end]
                set c_d [deheader $val content-disposition]
                lappend post [dict getdef $c_d name {}] $val
                set beg [expr {$end + 3}]
                set end [expr {[string first $sep $data $beg] - 1}]
            }
            dict set request post $post
        } text/plain {
            # Interpret text/plain POSTs.
            set post ""
            foreach elem [lrange [split $data \n] 0 end-1] {
                regexp {([^\r=]*)(?:(=[^\r]*))?} $elem _ key val
                if {$val ne ""} {
                    set val [list "" [string range $val 1 end]]
                }
                lappend post $key $val
            }
            dict set request post $post
        } text/xml {
            # Interpret text/xml POSTs, used for Web Services.
            dict set request post xml "" [dehex $data]
        } application/x-www-form-urlencoded - "" {
            # Interpret URL-encoded POSTs.
            dict set request post [dequery $data]
        }}
    }

    # The request has been received and parsed.  Return it to the caller.
    return $request
}

# Send the response to the client using HTTP.
proc ::wibbly::sendresponse {socket request response} {
    # Determine if the connection is persistent.
    set persist [expr {
        [dict get $request protocol] >= "HTTP/1.1"
     && ![string equal -nocase [dict getdef $request header connection {}] close]
    }]

    # Get the content channel and/or size.
    set size 0
    if {[dict exists $response contentfile]} {
        set size [file size [dict get $response contentfile]]
        if {[dict get $request method] ne "HEAD"} {
            set file [open [dict get $response contentfile]]
        }
    } elseif {[dict exists $response contentchan]} {
        if {[dict exists $response contentsize]} {
            set size [dict get $response contentsize]
        }
        set file [dict get $response contentchan]
    } elseif {[dict exists $response content]} {
        dict set response content [encoding convertto iso8859-1\
            [dict get $response content]]
        set size [string length [dict get $response content]]
    }

    # Parse range request header, and add content-range and -length headers.
    set begin 0
    set end [expr {$size - 1}]
    if {[regexp {^bytes=(\d*)-(\d*)$} [dict getdef $request header range {}]\
            _ begin end] && [dict get $response status] == 200} {
        dict set response status 206
        if {$begin eq "" || $begin >= $size} {
            set begin 0
        }
        if {$end eq "" || $end >= $size || $end < $begin} {
            set end [expr {$size - 1}]
        }
        dict set response header content-range "bytes $begin-$end/$size"
    }
    dict set response header content-length [expr {$end - $begin + 1}]

    # Add connection: close if this is not a persistent connection.
    if {!$persist} {
        dict set response header connection close
    }

    # Send the response header to the client.
    chan puts $socket "[dict get $request protocol] [dict get $response status]"
    chan puts $socket [headers2string [dict get $response header]]

    # If requested, send the response content to the client.
    if {[dict get $request method] ne "HEAD"} {
        chan configure $socket -translation binary
        if {[info exists file]} {
            # Asynchronously send response content from a channel.
            chan configure $file -translation binary
            if {$begin} {chan seek $file $begin}
	    set sizelimit [expr {$end - $begin + 1}]
	    set sizeopt [expr {$sizelimit ? "-size $sizelimit" : ""}]
            chan copy $file $socket {*}$sizeopt \
                -command [list ::wibbly::copydone $socket]
            coroutine::util vwait ::copydone$socket
            #set error [set ::copydone$socket] 
            #if {$error ne {}} {
                #error $error
            #}
        } elseif {[dict exists $response content]} {
            if {[catch {
                # Send buffered response content.
                coroutine::util puts -nonewline $socket [string range\
                    [dict get $response content] $begin $end]
            }]} {set persist 0}
        }
    }

    # Close the content file or channel.
    if {[info exists file]} {
        catch {chan close $file}
    }

    # Return 1 to keep going or 0 if the connection needs to close.
    return $persist
}

proc ::wibbly::copydone {socket size {error {}}} {
    set ::copydone$socket $error
}

# Main connection processing loop.
proc ::wibbly::process {params socket peerhost peerport} {
    set port [dict get $params -port]
    try {
        # Perform initial configuration.
        chan configure $socket -blocking 0

        # Main loop.
        while {1} {
            # Get request from client, then formulate a response to the request.
            set request [getrequest $port $socket $peerhost $peerport]
            set wob [wobbly new $request]
	    try {
                [dict get $params -handler] $wob
            } finally {
                set response [$wob getResponse]
            }
            $wob destroy

            # Send the response, and terminate or continue as requested.
            set persist [::wibbly::sendresponse $socket $request $response]
            ::wibbly::logAccess $params $request $response
            if {$persist} {
                catch {chan flush $socket}
                unset request response
            } else {
                catch {chan close $socket}
                break
            }
        }
    } on error {"" options} {
        # Pass errors to the panic handler.
        foreach var {request response} {
            if {![info exists $var]} {
                set $var {}
            }
        }
        set errInfo [dict get $options -errorinfo]
        ::wibbly::panic $params $errInfo $socket $peerhost $peerport $request $response
    } finally {
        catch {chan close $socket}
    }
}

# Open a server socket (default is plain socket, pass ::tls::socket for https),
# listen on the port (default 8080), and call handler to process each request
# received.  Handler will be called with a single argument, an instance of
# wobbly, the class of Web OBjects, documented below.  Note that ::wibbly::serve
# will return immediately, you need to enter the event loop, such as by calling
# vwait, to actually serve requests.  You can call ::wibbly::serve multiple
# times to start servers on multiple sockets, eg. one for http and another for
# https.
proc ::wibbly::serve args {
    set default_args {
        -handler ::wibbly::default_handler
        -port 8080
        -socketcmd socket
        -accesslog {/tmp/wibbly.$port.[clock format now -format {%y-%m-%d}].log}
        -errorlog /tmp/wibbly.$port.errors
        -error2user ::wibbly::default_error_report
    }
    set params [dict merge $default_args $args]
    set socketcommand [dict get $params -socketcmd]
    set port [dict get $params -port]

    {*}$socketcommand -server [list apply {{params socket peerhost peerport} {
        coroutine $socket ::wibbly::process $params $socket $peerhost $peerport
    } ::wibbly} $params] $port
}

# Default request handler, just show what was received.
proc ::wibbly::default_handler wob {
    append html {<h1>Wibbly Web Server</h1>}
    append html {<h3>Request received:</h3>}
    append html [::wibbly::template {
<table>
% dict for {key val} [dumpstate [$wob getRequest]] {
<tr><td>$key</td><td>$val</td></tr>
% }
</table>
    }]
    $wob htmlResponse $html
}

# ========================= logging etc. ===========================

# Log errors and report them to the client, if possible.
proc ::wibbly::panic {params errInfo socket peerhost peerport request response} {
    set port [dict get $params -port]
    set uri [dict getdef $request uri {}]
    variable errorcount
    incr errorcount
    set message "*** INTERNAL SERVER ERROR (BEGIN #$errorcount) ***"
    if {! [dict size $request] || [catch {
        dict for {key val} [dumpstate $request] {
            append message "\n$key: $val"
        }
    }]} {
        append message "\nport: $port"
        append message "\nsocket: $socket"
        append message "\npeerhost: $peerhost"
        append message "\npeerport: $peerport"
        append message "\nrawtime: [clock seconds]"
        append message "\ntime: [clock format [clock seconds]]"
        append message "\nuri: $uri"
    }
    append message "\nerrorinfo: $errInfo"
    append message "\n*** INTERNAL SERVER ERROR (END #$errorcount) ***\n"

    set err_log_name [subst [dict get $params -errorlog]]
    set err_log [open $err_log_name a]
    puts $err_log $message
    close $err_log

    # End users should get a message which is more meaningful to them
    # and exposes less internal detail
    set userError [dict get $params -error2user]
    lassign [$userError $uri $errInfo] code message
    dict set response status $code
    ::wibbly::logAccess $params $request $response

    catch {
        chan configure $socket -translation crlf
        chan puts $socket\
            "[dict get $request protocol] $code Internal Server Error\
            \ncontent-type: text/html;charset=utf-8\
            \ncontent-length: [string length $message]\
            \nconnection: close\n"
        chan configure $socket -translation lf -encoding utf-8
        chan puts $socket $message
    }
}

# Return the status code and message to be returned to the user
# when an internal error occurs.
proc ::wibbly::default_error_report {uri errInfo} {
    set date [clock format now -format {%Y-%m-%d %H:%M:%S} -gmt true]
    append html {
<h1>Server Error</h1>
Sorry, the server failed to process your request for
'} $uri {' at } $date { GMT. }
    return [list 500 $html]
}

set ::wibbly::logFile {}

# Write details of one request to an access log in the format supported
# by most webservers.  The first three fields can be customised via
# wobbly method setLogField.  An extra final field records processing
# time for the request in milliseconds.
proc ::wibbly::logAccess {params request response} {
    set port [dict getdef $request port 0]
    set peerhost [dict getdef $request peerhost -]
    set filename [subst [dict get $params -accesslog]]
    if {$filename eq {}} return
    if {$filename ne $::wibbly::logFile} {
        catch {close $::wibbly::accessLog}
	set ::wibbly::accessLog [open $filename a]
	set ::wibbly::logFile $filename
    }
    lappend fields [dict getdef $response logfields remote $peerhost]
    lappend fields [dict getdef $response logfields ident -]
    lappend fields [dict getdef $response logfields user -]
    set reqtime [dict getdef $request rawtime [clock seconds]]
    lappend fields \[[clock format $reqtime -format "%d/%h/%Y:%T %Z"]\]
    lappend fields "\"[dict getdef $request method -] [dict getdef $request uri -] [dict getdef $request protocol -]\""
    lappend fields [dict getdef $response status -]
    lappend fields [dict getdef $response header content-length -]
    foreach field {referer user-agent} {
        if {[dict exists $request header $field]} {
            lappend fields \"[dict get $request header $field]\"
        } else {
            lappend fields -
        }
    }
    # Non-standard extra field - processing time in milliseconds
    set nowms [clock milliseconds]
    set timems [dict getdef $request timems $nowms]
    lappend fields [expr {$nowms - $timems}] ;# processing time ms

    puts $::wibbly::accessLog [join $fields]
    flush $::wibbly::accessLog
}

# HTTP/1.0 error codes (the ones we use)
set ::wibbly::http_errors {
    200 {Data follows}
    204 {No Content}
    302 {Found}
    304 {Not Modified}
    400 {Bad Request}
    401 {Authorization Required}
    403 {Permission denied}
    404 {Not Found}
    408 {Request Timeout}
    411 {Length Required}
    419 {Expectation Failed}
    500 {Server Internal Error}
    501 {Server Busy}
    503 {Service Unavailable}
    504 {Service Temporarily Unavailable}
}

set ::wibbly::mimetypes {
application/javascript  ^js$                  application/json  ^json$
application/pdf ^pdf$                         audio/mid      ^(?:midi?|rmi)$
audio/mp4       ^m4a$                         audio/mpeg     ^mp3$
audio/ogg       ^(?:flac|og[ag]|spx)$         audio/vnd.wave ^wav$
audio/webm      ^webm$                        image/bmp      ^bmp$
image/gif       ^gif$                         image/jpeg     ^(?:jp[eg]|jpeg)$
image/png       ^png$                         image/svg+xml  ^svg$
image/tiff      ^tiff?$                       text/css       ^css$
text/html       ^html?$                       text/plain     ^txt$
text/xml        ^xml$                         video/mp4      ^(?:mp4|m4[bprv])$
video/mpeg      ^(?:m[lp]v|mp[eg]|mpeg|vob)$  video/ogg      ^og[vx]$
video/quicktime ^(?:mov|qt)$                  video/x-ms-wmv ^wmv$
image/ico       ^ico$
}

# Guess the content type from the URI extension.
proc ::wibbly::mimetype {path} {
    set extension [string tolower [string range [file extension $path] 1 end]]
    foreach {type pattern} $::wibbly::mimetypes {
        if {[regexp -nocase -- $pattern $extension]} {
            return $type
        }
    }
}

# ============================= new Web Object API =============================

oo::class create wobbly {

variable request response

constructor req {
    set request $req
    set response [dict create status 500]
}

# Returns the whole request
method getRequest {} {
    return $request
}

# Returns the path requested.
method getPath {} {
    dict getdef $request path {}
}

# Returns the named header line from the request or the empty string
# if it does not exist.
method getHeader name {
    dict getdef $request header [string tolower $name] {}
}

# Returns the value of the named cookie in the request, or the empty string
# if it does not exist.
method getCookie name {
    if {! [dict exists $request cookie]} {
        dict set request cookie [::wibbly::deheader $request header cookie]
    }
    dict getdef $request cookie $name {} {}
}

# Returns a name/value dict of all the form data sent in the request,
# whether by GET or POST method.  A file upload field will return the
# file content as the value here, it is left to the application code
# to write this out to a file if that is required.
method getFormdata {} {
    set data [dict create]
    foreach source {post query} {
        foreach {key val} [dict getdef $request $source {}] {
            dict set data $key [dict getdef $val {} {}]
        }
    }
    return $data
}

# Sets the literal html supplied as the response to be sent.
method htmlResponse {html} {
    dict set response status 200
    dict set response header content-type "text/html;charset=utf-8"
    dict set response content [encoding convertto $html]
}

# Sets the literal data supplied as the response to be sent,
# with the specified mime type.
method dataResponse {data type} {
    dict set response status 200
    dict set response header content-type $type
    dict set response content $data
}

# Sets the content of the file named by path as the response to be sent,
# with the specified mime type.
method fileResponse {path {type {}}} {
    if {$type eq {}} {set type [::wibbly::mimetype $path]}
    dict set response status 200
    dict set response header content-type $type
    dict set response contentfile $path
}

method chanResponse {type chan size} {
    dict set response status 200
    dict set response header content-type $type
    dict set response contentchan $chan
    dict set response contentsize $size
}

# Sets the cache-control header to specify that the content returned
# may be cached for not more than the specified number of seconds.
method cacheMaxAge {secs} {
    dict set response header cache-control "max-age=$secs"
}

# Sets the named header in the response to the given value.
method setHeader {args} {
    dict set response header {*}$args
}

# Sets the response to have the specified error code, and optionally
# add the html in detail to give further information.
method errorResponse {code {detail ""}} {
    set uri [dict get $request uri]
    set errorFormat {
<title>Httpd_Error: %1$s</title>
Got the error <b>%2$s</b><br>
while trying to obtain <b>%3$s</b>.
}
    set errorString [dict getdef $::wibbly::http_errors $code "Error $code"]
    set message [format $errorFormat $code $errorString $uri]
    append message <br>$detail

    dict set response status $code
    dict set response header content-type "text/html;charset=utf-8"
    dict set response content $message
}

# Sets the response to tell the client to redirect to the specified URL.
method redirect newurl {
    dict set response status 301
    dict set response header location $newurl
}

# The first three fields in the access log are named remote, ident and user.
# This method will set the specified field to the given value.
method setLogField {field value} {
    if {$value eq {}} return
    dict set response logfields $field $value
}

method getResponse {} {
    return $response
}

# Forward the request to a program which provides an SCGI interface on the
# specified host and port.  Additional argument pairs of name and value
# can be supplied to set or override headers in the SCGI request.
# The HTTP response will then be set from the SCGI response.
method scgi {host port args} {
    # Open channel to SCGI server
    set sock [::socket $host $port]
    chan configure $sock -translation binary -blocking 0
#printvars host port args

    # Encode request and send to SCGI server
    set rawpost [dict getdef $request rawpost {}]
    set script_name [dict getdef $args SCRIPT_NAME {}]
    dict unset args SCRIPT_NAME

    set hdrs [dict create \
        CONTENT_LENGTH [string length $rawpost] \
        SCGI 1 \
        REQUEST_METHOD [dict get $request method] \
        REQUEST_URI [dict get $request uri] \
        SCRIPT_NAME $script_name \
        QUERY_STRING [dict getdef $request rawquery {}] \
    ]
    dict for {key val} [dict get $request header] {
        if {$key eq "content-length"} continue
        set key [string toupper [string map {- _} $key]]
        if {$key ne "CONTENT_TYPE"} {set key HTTP_$key}
        dict set hdrs $key $val
    }
    dict for {key val} [dict merge $hdrs $args] {
        append scgi_hdrs "$key\0$val\0"
    }

    set hdrlen [string length $scgi_hdrs]
#printvars rawpost hdrlen scgi_hdrs
    coroutine::util puts -nonewline $sock "$hdrlen:$scgi_hdrs,$rawpost"
    flush $sock

#printvars WAITING
    # Read and decode response from SCGI server
    set scgi_resp [coroutine::util read $sock]
    set endhdr [string first \r\n\r\n $scgi_resp]
    set hdrs [::wibbly::string2headers [string range $scgi_resp 0 $endhdr]]
    set body [string range $scgi_resp $endhdr+4 end]
#printvars hdrs

    # Copy to our response
    scan [dict get $hdrs status] %d status
    dict set response status $status
    dict unset hdrs status
    dict set response header $hdrs
    dict set response content $body
}

}

# Wibbly has been loaded successfully.
package provide wibbly 0.5

# vim: set sts=4 sw=4 tw=80 et ft=tcl:
