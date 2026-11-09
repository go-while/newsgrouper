# Newsgrouper - a web interface to Usenet.

set ng_version 0.9.0

package require Tcl 9.0
package require mime
package require sqlite3
package require cmdline

source scripts/nntp.tcl
#source scripts/reactcl.tcl
source scripts/config.tcl
source scripts/utils.tcl
source scripts/captcha.tcl

::tcl::tm::path add scripts
package require wibbly
package require retcl
source scripts/distcl.tcl

# The back-end "newsgetter" process(es) provide "ng" and "na" services via distcl
set redis [retcl new] ;# TODO options
$redis -async
interp alias {} get {} distcl::get -coro redis
interp alias {} prefetch {} distcl::prefetch redis
interp alias {} html {} append html
proc tmpl {var body} {
    upvar 1 $var html
    append html [uplevel 1 ::wibbly::template [list $body]]
}

sqlite3 overdb $over_db -fullmutex 1
overdb timeout 20000

set postbatch 500

set cmd_opts [::cmdline::getoptions argv {
    {port.arg 8080 "port for http"}
    {sport.arg 0 "port for https"}
}]

# Each coroutine needs a separate Redis connection, keep a pool of them
set freeRedis {}
proc reqHandler req {
    coroutine::util global redis
    if {[llength $::freeRedis]} {
        set redis [lpop ::freeRedis]
    } else {
        set redis [retcl new] ;# TODO options
        $redis -async
    }
    try {
        main $req
    } finally {
        lappend ::freeRedis $redis
    }
}
proc redis args {
    coroutine::util global redis
    tailcall $redis {*}$args
}

# return html page heading
proc heading params {
    dict with params {}
    coroutine::util global page_title
    html "<!doctype html>
    <head><title>[enpre1 $page_title]</title>
    <style type='text/css'>
    body {color:$gen_fg; background-color: $gen_bg; font-family: Verdana}
    .but {width: 8em;}
    .bbut {width: 10em;}
    .new {color:$new_fg; background-color: $new_bg}
    .rep {color:$rep_fg; background-color: $rep_bg}
    .quot {color: $quo_fg; background-color: $quo_bg}
    .hide {color: red; text-decoration: none; font-size: x-small}
</style></head>"
    html {
<body onload='try {setup();} catch {}'>
<a id='home' href=/><span style='font-size: xx-large'>Newsgrouper <span style='color:green'>&#x1F5E8;</span> &#x1F4AC; <span style='color:red'>&#x1F5EF;</span> &#x1F4AD;
</span></a>
<span style='float: right'><br/>
<form action='/logout' method='post' style='display: inline'>
<input type=submit value='Help' formaction='/help.htm' class='but'/>
<input type=submit value='Preferences' formaction='/preferences' class='but' />
<input type=submit value='Log Out' class='but' />
</form>
</span>
<br/>}
    return $html
}
proc page_title title {
    coroutine::util global page_title
    set page_title $title
}

# Main page - check login status, then dispatch as required.
proc main {sock} {
    set suffix [string trimleft [$sock getRequest path] /]
    page_title Newsgrouper

    set country [$sock getHeader cf-ipcountry] ;# Cloudflare-specific!
    $sock setLogField remote $country
    #tailcall show_down $sock
    if {[serve_static_file $sock $suffix]} return
    if {[redirect_old_domain $sock $suffix]} return

    set urec [get_user_record $sock]
    lassign $urec user can_post params

    if {[dict exists $params captcha]} {
        tailcall check_captcha $sock $urec $suffix
    }
    if {[string match -nocase news:* $suffix]} {
        set suffix [string range $suffix 5 end]
    }
    if {[regexp {^(<[[:graph:]]+>)([mwrv]{0,4})$} $suffix - msgid flags]} {
        tailcall do_msgid_art $urec $sock $msgid $flags
    }
    switch -- $suffix {
        tops {tailcall do_tops $urec $sock}
        do_login {tailcall do_login $sock}
        do_guest {tailcall do_guest $sock}
    }
    if {$country eq "GB"} {
        tailcall osa_block $sock
    }
    # If user is not logged in, show the login page
    if {$user == 0} {
        if {[hack_attack $sock $suffix]} return
        tailcall show_login $sock $suffix
    }

    if {[dict getdef $params banned 0]} {
        $sock errorResponse 403 BANNED
        return
    }
    #if {[need_warn $sock $urec]} {
    #    tailcall do_warn $sock $suffix $urec
    #}
    #if {[need_survey $sock $urec]} {
    #    tailcall do_survey $sock $suffix $urec
    #}

    # User is logged in, process their request and return the page
    switch -regexp -matchvar matches $suffix {
    {^$} {
        html [general_info $urec]
        html [show_groups_read $urec $sock]
        html [show_group_search]
        html [show_msgid_search]
        html [other_info] }
    {^([[:alnum:]_\-\+]+\.[[:alnum:]_\.\-\+]+)(/.*)?$} {
        lassign $matches - group rest
        tailcall dispatch_group $urec $sock $group $rest }
    {^face/([[:graph:]]+)\.png$} {
        lassign $matches - addr
        tailcall get_face $sock $addr }
    {^login$} {
        tailcall show_login $sock $suffix }
    {^logout$} {
        tailcall do_logout $urec $sock }
    {^msgid$} {
        html [do_msgid_search $urec $sock] }
    {^search$} {
        html [do_group_search $urec $sock] }
    {^preferences$} {
        html [edit_prefs $urec $sock] }
    {^pref_(x?)face(\d*)$} {
        lassign $matches - fx id
        html [pref_face $urec $sock $fx $id] }
    {^tmp_face/(\d+)\.png$} {
        lassign $matches - id
        tailcall tmp_face $sock $id }
    {^testy$} {
        html [do_testy $urec $sock] }
    default {
        tailcall dispatch_action $urec $sock $suffix }
    }
    set footing {</body>}
    $sock htmlResponse [heading $params]$html$footing
}

# Guard against XSS attempts
proc ok_post sock {
    set method [$sock getRequest method]
    if {$method ne "POST"} {return 0}

    set port [$sock getRequest port]
    if {$port != $::sport} {return 1}

    set here "https://$::this_site"
    set origin [$sock getHeader origin]
    if {$origin ne {}} {return [string equal $origin $here]}

    set referer [$sock getHeader referer]
    if {$referer ne {}} {return [string match $here/* $referer]}

    return 1
}

# Request specifies an action or is bogus, check and process.
proc dispatch_action {urec sock suffix} {
    lassign $urec user can_post params
    if {! [ok_post $sock]} {set suffix "'$suffix'"}

    switch -exact $suffix {
    post {
        html [do_post $urec $sock] }
    do_block {
        tailcall do_block $sock }
    block {
        tailcall save_block $urec $sock }
    save_prefs {
        html [save_prefs $urec $sock] }
    load_face {
        tailcall load_face $sock}
    save_face {
        tailcall save_face $urec $sock }
    face_data {
        tailcall face_data $urec $sock }
    markup {
        tailcall toggle_pref $urec $sock mup }
    reflow {
        tailcall toggle_pref $urec $sock flo }
    rot13 {
        tailcall toggle_rot13 $urec $sock }
    allthr {
        tailcall toggle_pref $urec $sock apt }
    reset_colours {
        tailcall reset_colours $urec $sock }
    change_pass {
        tailcall change_pass $urec $sock }
    default {
        html "<br/>[enpre1 $suffix] - THAT DOES NOT COMPUTE."
    } }

    set footing {</body>}
    $sock htmlResponse [heading $params]$html$footing
}

# Request specifies a group, process the rest of it.
proc dispatch_group {urec sock group rest} {
    lassign $urec user can_post params
    if {! $can_post && [bot_check $urec $group $rest]} {
        tailcall make_captcha $sock $urec $group$rest
    }

    if {! [dict exists $::Groupstats $group] && $group ne "all.all"} {
        set rest { not found}
    }
    switch -regexp -matchvar num_etc $rest {
    {^$} {
        html [show_group $sock $urec $group] }
    {^/(\d+)$} {
        lassign $num_etc - num
        html [show_thread $urec $group $num $num 0] }
    {^/(\d+)/(\d+)$} {
        lassign $num_etc - start num
        html [show_thread $urec $group $start $num 0] }
    {^/(\d+)/raw$} {
        lassign $num_etc - num
        tailcall show_article_raw $sock $group $num }
    {^/(\d+)/post$} {
        lassign $num_etc - num
        html [compose_reply $urec $group $num] }
    {^/older/(\d+)$} {
        lassign $num_etc - num
        html [show_group $sock $urec $group $num] }
    {^/post$} {
        html [compose_new $urec $group] }
    {^/search/list$} {
        html [show_art_search $sock $urec $group] }
    {^/search/(\d+)$} {
        lassign $num_etc - num
        html [show_thread $urec $group $num $num 1] }
    {^/search/(\d+)/(\d+)$} {
        lassign $num_etc - start num
        html [show_thread $urec $group $start $num 1] }
    {^/<([[:graph:]]+)>$} {
        lassign $num_etc - msgid
        tailcall group_msgid $sock $group $msgid }
    {^/rev$} {
        tailcall reverse_group $sock $urec $group }
    {^/hide$} {
        tailcall hide_group $sock $urec $group }
    {^/charter$} {
        html [show_charter $group] }
    default {
        html "<br/>'[enpre1 $group$rest]' - COMPUTER SAYS NO."
    } }

    set footing {</body>}
    $sock htmlResponse [heading $params]$html$footing
}

# If the request is just for a static file, handle it here and return 1.
# If not return 0.
proc serve_static_file {sock suffix} {
    switch -glob -- $suffix {
	apple-touch-icon*.png {
            $sock fileResponse htdocs/newsgrouper-icon.png image/png
            return 1
        }
        favicon.ico -
        robots.txt -
        *.asc -
        *.htm -
        *.svg -
        *.png -
        *.gif {
            if {! [file readable htdocs/$suffix]} {return 0}
            $sock cacheMaxAge $::week_secs
            $sock fileResponse htdocs/$suffix
            return 1
        }
    }
    return 0
}

proc hack_attack {sock suffix} {
    switch -glob -- $suffix {
        {} {return 0}
        *.php -
        *.cgi -
        *.aspx {set mimetype text/html}
	sitemap*xml -
	.well-known/* {
            coroutine::util after 1000
            $sock errorResponse 404 "Return to sender, address unknown, no such number, no such zone."
            return 1
        }
        *.zip -
        *.json -
        .* -
        */.* -
        wp-* -
        */wp-* {set mimetype text/plain}
	{%*/search/list} -
	{*+*/search/list} {
            coroutine::util after 5000
            $sock dataResponse {AWANBILEYERHEIDYEBAMPOT
Some Automated Insanity thinks this site is a search engine.  It is not.  The sooner the AI bubble pops, the better!} text/plain
            return 1
        }
	default {
            # if the request looks only potentially dodgy, delay reply for 3 seconds
            if {[regexp {\d{9,}} $suffix]
                || ! [regexp {^[[:alnum:]_\-\+]+\.[[:alnum:]_\.\-\+]+} $suffix]} {
	      coroutine::util after 3000}
            return 0
        }
    }

    # Request is probing for vulnerabilities, serve them something appropriate.
    coroutine::util after 2000
    if {rand() < 0.2} {
        $sock errorResponse 404 "This is not the page you are looking for."
        return 1
    }
    if {rand() < 0.2} {
        $sock redirect http://localhost/
        return 1
    }
    coroutine::util after [expr {int(rand()*50000)}]
    $sock setHeader content-encoding gzip
    if {rand() < 0.2} {
        # Files hex[0-4] are gzipped containing various repetitions of
        # "Don't mention it. ++???++ Out of Cheese Error. Redo From Start."
        set file hex[expr {[string length $suffix] % 5}]
        $sock fileResponse htdocs/$file $mimetype
    } elseif {rand() < 0.2} {
        # generate and return a random amount (<=100kB) of random crap
        exec head -[expr {int(rand()*100000)}]c /dev/urandom > htdocs/random
        $sock fileResponse htdocs/random $mimetype
    } else {
        # return an error
        $sock errorResponse 403 "On yer bike Jimmy!"
    }
    return 1
}

proc local_url suffix {
    set suffix [string trimleft $suffix "/\\"]
    return /[::wibbly::enhex $suffix {[^-/.,_~!$+=:@A-Za-z0-9]}]
}

# Show the login page for guest or registered user.
proc show_login {sock suffix} {
    html {
<head><title>Newsgrouper: A web interface to Usenet discussion groups</title>
<meta name='description' content='Read and post to Usenet Newsgroups with a simple web interface.'></head>
<body style='color: black; background-color: lightblue; font-family: Verdana'>
<span style='font-size: xx-large; color: purple'>Newsgrouper
<span style='color:green; margin-left: 20px'> &#x1F5E8;</span> &#x1F4AC; <span style='color:red'>&#x1F5EF;</span> &#x1F4AD;
</span>
<br/>
<span style='font-size:large'>
A web interface to Usenet discussion groups (no binaries)
</span>
<br/><br/>
<form action='/do_login' method='post'>
<span style='font-size: large; width: 20%; float: left'>Email:<br/>Password:</span>
<input type='text' name='email' size='40' maxlength='100'/>
<br/>
<input type='password' name='pass' maxlength='100'/>
<input type=submit value="Login" style='width: 10%' />
<br/>
<br/>
<span style='font-size: large; width: 20%; float: left'>New users can</span>
<input type=submit value="Register" formaction='/terms.htm' />
- required for posting.
<br/>
<br/>
<span style='font-size: large; width: 20%; float: left'>Alternatively</span>
<input type=submit value="Continue as Guest" formaction='/do_guest' />
- this allows reading but not posting.
<br/>
<br/>
<div style='color: red'>
<em>Cookies</em>
- Using this site requires setting a single 'cookie' on your device to record the fact
that you have logged in, either as a registered user or as a guest.
This cookie is not used for any other purpose, and no other cookies are used.
</div>
<br/>
<br/>
<input type=submit value="Help/About/Contact Info." formaction='/help.htm' />
    }
    html "<input type='hidden' name='suffix' value='[enpre1 $suffix]' />\n"
    html {</form></body>}
    $sock htmlResponse $html
}

sqlite3 userdb $::user_db ;# -fullmutex 1
#userdb timeout 1000

package forget md5
package require md5
package require md5crypt

# Do login process for a registered user
proc do_login sock {
    set missing [GetQuery $sock email pass suffix]
    if {[llength $missing]} {
        $sock htmlResponse "<h3>Missing fields: $missing.</h3>"
        return
    }

    set fail_html {
<body style='background-color: pink'>
<h1>Newsgrouper Login Failed</h1>
Sorry, your email/password combination was not recognised.
<br/><br/> }
    append fail_html "<a href='[local_url $suffix]'>Try again.</a><br/><br/>"
    append fail_html {Alternatively <a href='/do_guest'>Continue as Guest</a>
- this allows reading but not posting.
</body>}

    if {$email eq "" || $pass eq ""} {
        $sock htmlResponse $fail_html; return
    }
    # Check the credentials are valid
    set enc_email [md5crypt::md5crypt $email $::user_salt]
    set user {}
    set dummypass [md5crypt::salt]

    lassign [userdb eval {SELECT num,pass FROM users WHERE email == $enc_email}] num dbpass
    if {$dbpass eq {}} {set dbpass $dummypass} ;# to dodge timing attack
    if {[md5crypt::md5crypt $pass $dbpass] eq $dbpass} {set user $num}

    if {$user eq {}} {
        $sock htmlResponse $fail_html; return
    }
    # Generate cookie for user, write to their db record
    set cookie [do_cookie $sock]
    userdb eval {UPDATE users SET cookie = $cookie WHERE num = $user}

    html "<body style='background-color: lightgreen'> [login_message 1]"
    if {$suffix eq "login" || $suffix eq "logout"} {set suffix ""}
    html "<form action='[local_url $suffix]' method='post'>
<input type=submit value='Continue' style='width: 20%' />
</form></body>"
    $sock htmlResponse $html
}

# Generate random cookie for user session
proc do_cookie sock {
    set dough [string range [clock clicks] end-7 end]
    set bake [md5crypt::md5crypt $dough [md5crypt::salt]]
    regsub {^\$.\$.*\$} $bake {} cookie
    set cookie_hdr "userhash=$cookie; Max-Age=$::year_secs; HttpOnly"
    set port [$sock getRequest port]
    if {$port==$::sport} {append cookie_hdr "; Secure"}
    $sock setHeader set-cookie $cookie_hdr
    return $cookie
}

# Return text for login confirmation page (guest or user)
proc login_message registered {
    tmpl html {<h1>Newsgrouper Login</h1>

%    set usertype [expr {$registered ? "Registered User" : "Guest"}]
    Logging in as a $usertype ...

<br/><br/>
<em>This sets the only cookie this site uses.<br/>
It can be removed by clicking <strong>Log Out</strong>.</em>
<br/><br/>

%    if {! $registered} {
            Note that as a guest, logging out will forget your history and preferences,
            so when you return it will not be possible to show what postings are new
            since your previous visit.
%    }
    As a registered user you can log out without losing your history and preferences.
    <br/><br/>}
}

# Do login process for a guest
proc do_guest sock {
    set suffix {}
    GetQuery $sock suffix

    # Generate cookie for user, write a temporary db record for them
    set cookie [do_cookie $sock]
    userdb eval {INSERT INTO users(cookie) VALUES($cookie)}

    html {<body style='background-color: khaki'>
} [login_message 0] "<form action='[local_url $suffix]' method='post'>
<input type=submit value='Continue' />
</form></body>"
    $sock htmlResponse $html
}

# Check if the user is logged in.
# If so, return their user number, whether they can post, and their
# preference settings.  If not, return user number 0.
proc get_user_record sock {
    set nouser [list 0 0 [dict merge $::param_defaults $::colour_defaults] {}]
    # Get the user's cookie
    set userhash [$sock getCookie userhash]
    if {$userhash in {{} 0}} {return $nouser}

    # Find the user's db record
    userdb eval {SELECT num,email,params FROM users WHERE cookie == $userhash} {
        $sock setLogField user $num
        set can_post [expr {$email ne {}}]
        if {$can_post} {$sock setLogField ident *}
        set params [dict merge $::param_defaults $::colour_defaults $params]
        set ugrps [redis hgetall "ugrp $num"]
        return [list $num $can_post $params $ugrps]
    }
    return $nouser
}

# Guest users pulling old posts may be AI trawlers.
# Return whether to give them a captcha.
# This will happen on their first attempt, and 20% of the time thereafter.
# If captcha has been solved for a page, allow the page on next attempt.
set bot_check_newest [clock scan {1/1/2023}]
set bot_check_oldest [clock scan {1/1/1980}]
proc bot_check {urec group rest} {
    lassign $urec user can_post params
#printvars bot_check user rest params

    if {! [regexp {\d+} $rest dat]} {return 0}
    if {$dat > $::bot_check_newest} {return 0}
    if {$dat < $::bot_check_oldest} {return 0}
    if {! [dict exists $params capok]} {return 1}
    if {[dict get $params capok] eq "$group$rest"} {return 0}
    return [expr {rand() < 0.2}]
}

proc check_captcha {sock urec suffix} {
    lassign $urec user can_post params
    set cap_expected [dict get $params captcha]
    set cap_supplied [$sock getFormdata captcha]
printvars user cap_expected cap_supplied

    if {$cap_supplied != $cap_expected} {
        tailcall make_captcha $sock $urec $suffix
    }
    dict unset params captcha
    dict set params capok $suffix
    userdb eval {UPDATE users SET params = $params WHERE num = $user}
    $sock redirect [local_url $suffix]
}

proc make_captcha {sock urec suffix} {
    lassign $urec user can_post params
    coroutine::util after 2000

    # Bot defense - generate a 'captcha' question and answer
    lassign [captcha] cap_question cap_answer
    dict set params captcha $cap_answer
    userdb eval {UPDATE users SET params = $params WHERE num = $user}

    html "<h1>Please answer the following question</h1>
<form action='[local_url $suffix]' method='post'> $cap_question
<input type=submit value='Continue' /> </form>"
    $sock htmlResponse $html
    $sock setLogField ident ?
}

# Do logout confirmation page and complete the logout process (guest or user)
proc do_logout {urec sock} {
    lassign $urec user can_post

    # Remove the db record for a guest
    userdb eval {DELETE FROM users WHERE num == $user and email IS NULL}
    # Remove cookie from their db record if registered user
    userdb eval {UPDATE users SET cookie = NULL WHERE num = $user}

    # TODO - for guest remove ugrp

    # Clear the cookie
    $sock setHeader set-cookie "userhash=0; Max-Age=0"

    html {<h1>Newsgrouper Logout</h1>
Logging Out...
<br/><br/>
<em>This clears the only cookie this site uses.</em>
<br/><br/>
<form action='/' method='post'>
<input type=submit value='Continue' style='width: 20%' />
</form>}
    $sock htmlResponse $html
}

# Show the home page first section with general information
proc general_info urec {
    lassign $urec user can_post
    tmpl html {
A web interface to Usenet discussion groups (no binaries)
<span style='float: right'>
<form action='/none' method='post'>

    <input type=submit value='[expr {$can_post ? "Terms" : "Register"}]' formaction='/terms.htm'  class='but'/>
    </form></span><br/>}
}

# Show the list of groups this user has previously read
proc show_groups_read {urec sock} {
    lassign $urec user can_post

    set prev_group {}
    set group_re {^https?://[^/]+/([[:alnum:]_\-\+]+\.[[:alnum:]_\.\-\+]+)}
    regexp $group_re [$sock getHeader referer] - prev_group

    html {
<script type='text/javascript'>
function setup() {
	document.getElementById('sel').focus();
}
</script>
}
    # [get nh counts] gets the list of groups the user has previously read.
    # For each group returns name, number of new posts since last 
    # read by this user & whether any of those is a reply to a post
    # by this user.
    set groups_read [get nh counts $user]
    if {[llength $groups_read] == 0} {return ""}

    html {
<span style='clear: right; float: right'><br/>
<form action='/all.all/search/list' method='post' style='display: inline'>
<input type=submit value='Search within these groups } "\U01F50D" {' >
</form></span>
<h3>Groups previously read</h3>
<table><thead>
<tr align='left'><th>Name</th><th>Description</th><th>New</th><th></th></tr>
</thead><tbody>
    }

    foreach {group new new_reply} $groups_read {
        lassign [groupstat $group] desc status
        if {$status eq {}} continue
	set new [expr {max(0, $new - [count_xnew $user $group])}]

        if {$new} {
            if {$new_reply} {
                html "<tr class='rep'>"
            } else {
                html "<tr class='new'>"
            }
        } else {
            html "<tr>"
        }
        # If we came here from a previous group, select that,
        # otherwise select the first group with new posts.
        set id {}
        if {$group eq $prev_group} {
            set id " id='sel'"
        }
        if {$new && $prev_group eq {}} {
            set id " id='sel'"
            set prev_group .
        }
        html "<td><a$id href=/$group>$group</a></td><td>[enpre1 $desc]</td><td>$new</td>"
        html "<td><a href=/$group/hide class='hide' tabindex='-1'>\U274C</a></td></tr>\n"
    }

    html "</tbody>\n</table>\n"
    return $html
}

# Show the form to search for groups
proc show_group_search {} {
    html "<h3>Find groups to read ($::numgroups groups available)</h3>"
    html {
<form action='/search' method='post'>
<input type='radio' name='pat' value='0' checked='checked' />Including this Text:
<input type='radio' name='pat' value='1' />Matching this Pattern:
<br/>
<input type='text' name='text' size='50' maxlength='100'/>
<input type=submit value="Search" class='but' />
<br/>
<input type='checkbox' name='name' value='1' checked='checked' />In the Group Name
<input type='checkbox' name='desc' value='1' />In the Description
<br/>
</form>
}
    return $html
}

# Run a group search and show the results
proc do_group_search {urec sock} {
    lassign $urec user can_post params
    set desc 0
    set name 0
    set missing [GetQuery $sock pat text name desc]
    if {[llength $missing]} {return "<h3>Missing fields: $missing.</h3>"}

    if {$pat} {
        set pattern $text
    } else {
        set pattern *$text*
    }
    set match_name [expr {$name == 1}]
    set match_desc [expr {$desc == 1}]
    set groups [groups_matching $pattern $match_name $match_desc]

    html {
<h3>Groups Found</h3>

<table>
<thead>
<tr><th>Name</th><th>Description</th><th>Activity</th></tr>
</thead>
<tbody>
    }

    foreach {group desc} $groups {
        set act [redis zscore newposts $group]
        html "<tr><td><a href=/$group>$group</a></td>" \
            "<td>[enpre1 $desc]</td><td align='right'>$act</td></tr>\n"
    }

    html "</tbody>\n</table>\n<br/><br/>"

    if {[llength $groups] == 0} {set html {<h3>No Groups Found</h3>}}

    html [show_group_search]
    return $html
}

# Show the form to search for a message by its id
proc show_msgid_search {} {
    html {
<h3>Find an article by message-id</h3>

<form action='/msgid' method='post'>
Message-Id: <em>(this has the form &lt;random-stuff@some.site&gt;)</em>
<br/>
<input type='text' name='msgid' size='50' maxlength='100'/>
<input type=submit value="Search" class='but' />
<br/>
</form>
}
    return $html
}

# Run a msgid search and show the result
proc do_msgid_search {urec sock} {
    set missing [GetQuery $sock msgid]
    if {[llength $missing]} {return "<h3>Msgid missing.</h3>"}
    set msgid [string trim $msgid]
    if {! [regexp {^<[[:graph:]]+>$} $msgid]} {
        return "<h3>Invalid message-id: '[enpre1 $msgid]'.</h3>"
    }
    html [show_art_byid $urec $msgid {}]
    return $html
}

proc do_msgid_art {urec sock msgid flags} {
    lassign $urec user can_post params
    html [heading $params]
    html [show_art_byid $urec $msgid $flags]
    html {</body>}
    $sock htmlResponse $html
}

proc show_art_byid {urec msgid flags} {
    lassign $urec user can_post params
    html "<h3>Article with message-id: [enpre1 $msgid]</h3>"
    if {[catch {get nh mid $msgid} art]} {
        html "<h4>Article Not Found.</h4>"
	return $html
    }
    foreach {flag param} {
        m mup
	w flo
	r r13
        v vs
    } {
        set on($flag) [expr {[string first $flag $flags] != -1}]
        dict set params $param $on($flag)
        if {$on($flag)} {
            set flipflag($flag) [string map [list $flag {}] $flags]
        } else {
            set flipflag($flag) $flag$flags
        }
    }

    if {$on(v)} {
        html "<pre>\n[enpre1 $art]\n</pre>\n"
    } else {
        lassign [parse_article $art] headers body
        html [show_article $user $params $headers $body]
    }

    html {<form action='/' method='post' >}
    html "\n<input type=submit value='[tick $on(v)] View Source' formaction='[local_url $msgid$flipflag(v)]' />"
    html "\n<input type=submit value='[tick $on(w)] Wrap' formaction='[local_url $msgid$flipflag(w)]' />"
    html "\n<input type=submit value='[tick $on(m)] Markup' formaction='[local_url $msgid$flipflag(m)]' />"
    html "\n<input type=submit value='[tick $on(r)] Rot13' formaction='[local_url $msgid$flipflag(r)]' />"
    html {</form>}
}

proc do_tops {urec sock} {
    lassign $urec user can_post params
    html [heading $params]
    html [top_groups_read]
    html [top_groups_posted]
    html [big8_active_list]
    html {</body>}
    $sock htmlResponse $html
}

proc other_info {} {
    html {<h3><a href='/tops'>Guide to the most active groups</a></h3>}
    html {<h3>Support Group for this site: 
    <a href='/newsgrouper.support'>newsgrouper.support</a></h3>
    }
}

# Show the list of groups most read by all users here
proc top_groups_read {} {

    set group_list {}
    set total_reads 0
    set group_reads [redis zrange groupreads 0 -1 rev withscores]
    if {[llength $group_reads] == 0} return

    foreach {group reads} $group_reads {
        catch { incr total_reads $reads }
        if {[llength $group_list] < 20} {
            lappend group_list $group
            lappend read_list $reads
        }
    }

    html {
<h3>Top twenty groups most read on this site</h3>
<table><thead>
<tr align='left'><th>Name</th><th>Description</th><th>Reads</th></tr>
</thead><tbody>
    }

    foreach group $group_list reads $read_list {
        set percent [expr {100 * $reads / $total_reads}]
	lassign [groupstat $group] desc

        html "<tr><td><a href=/$group>$group</a></td><td>[enpre1 $desc]</td><td align='right'>$percent%</td></tr>\n"
    }

    html "</tbody>\n</table>\n"
    return $html
}

# Show the list of groups most posted to by all users globally
proc top_groups_posted {} {

    set total_reads 0
    set group_posts [redis zrange newposts 0 19 rev withscores]
    if {[llength $group_posts] == 0} return

    html {
<h3>Top twenty groups with most posting activity globally</h3>
<table><thead>
<tr align='left'><th>Name</th><th>Description</th><th>Activity</th><th></th></tr>
</thead><tbody>
    }

    foreach {group posts} $group_posts {
        lassign [groupstat $group] desc status
        if {$status eq {}} continue

        html "<tr><td><a href=/$group>$group</a></td>" \
            "<td>[enpre1 $desc]</td><td align='right'>$posts</td></tr>\n"
    }

    html "</tbody>\n</table>\n"
    return $html
}

# show the list of active groups provided by big-8.org
proc big8_active_list {} {
    set input [open scripts/Sample-newsrc.txt]
    while {[gets $input line] >= 0} {
        set group [string trim $line { :}]
        lappend group_list $group
    }
    close $input

    html {
<h3>Active groups list from
<a href='https://www.big-8.org/w/images/3/3e/Sample-newsrc.txt'>big-8.org</a></h3>
<table><thead>
<tr align='left'><th>Name</th><th>Description</th></tr>
</thead><tbody>
    }

    foreach group $group_list {
        lassign [groupstat $group] desc status
        if {$status eq {}} continue

        html "<tr><td><a href=/$group>$group</a></td><td>[enpre1 $desc]</td></tr>\n"
    }

    html "</tbody>\n</table>\n"
    return $html
}

# Hack to avoid ::mime::field_decode failure on Chinese posts using charset GBK,
# see KBK's note at https://wiki.tcl-lang.org/page/Encoding+Translations+and+i18n
set ::mime::reversemap(gbk) gb2312
set ::mime::reversemap(cp1252) cp1252 ;# WTF! FIXME

# Show the list of discussion threads for a group
proc show_group {sock urec group {older 0}} {
    lassign $urec user can_post
    page_title $group
    set prev_thread 0
    set prev_thread_re "/[string map {. \\. + \\+} $group]/(\\d+)"
    regexp $prev_thread_re [$sock getHeader referer] - prev_thread
    if {$prev_thread} {
        GetStash u$user.$group older
    } else {
        PutStash u$user.$group older
	clear_xnew $user $group
    }

    html {
<script type='text/javascript'>
function keyDown(event) {
	//console.log('keyDown', event);
	const me = new MouseEvent('click');
	if (event.key == 'Escape') {
		let topDoc = window.top.document;
		topDoc.getElementById('home').dispatchEvent(me);
        }
}
function setup() {
	window.addEventListener('keydown', keyDown);
	document.getElementById('sel').focus();
}
</script>
}
    lassign [groupstat $group] desc status
    if {$status eq {}} {
        return "<h3>Group '$group' not found.</h3>"
    }

    html "<span style='clear: right; float: right'>"
    html "<form action='/$group/post' method='post' style='display: inline'>"
    html "<input type=submit value='New Thread \U01F4DD' class='but' "
    if {! $can_post || $status eq "x"} {
        html {disabled='disabled' }
    }
    html "/> <input type=submit value='Search \U01F50D' class='but' "
    html "formaction='/$group/search/list' />\n"

    html {<input type=submit value='Group Charter' class='but' }
    html "formaction='/$group/charter' />\n"
    html "</form></span>\n"

    html "<h3><a href='/$group'>$group</a> '[enpre1 $desc]'</h3>\n"
    html "<base href='/$group/0' />\n"

    set threadinfo [cacheThreadinfo $urec $group $older 0]
    dict with threadinfo {}

    set last [lindex $hdrs end-1]
    update_last $urec $group $last

    html {
<table style='table-layout: fixed; width:100%;' >
<colgroup>
<col style='width: 60%;' />
<col style='width: 20%;' />
<col style='width: 10%;' />
<col style='width: 5%;' />
<col style='width: 5%;' />
</colgroup>

<thead>
<tr align='left'><th>Thread Subject</th><th>Original Poster</th>
} "<th><a href=/$group/rev>Date</a></th>" {
<th align='right' style='font-size: x-small'>Posts</th>
<th align='right' style='font-size: x-small'>New</th>
</tr></thead>
<tbody>
    }

    set looking_for_new [expr {! $prev_thread}]
    foreach {start_num thread} $threads {thread_posts new_posts replies} $threadcounts {
        lassign [dict get $hdrs $start_num] prev sub frm tim id
        set sub [encoding convertfrom $sub]
        set frm [encoding convertfrom $frm]
        if {[string length $sub] > 100} {
            set sub [string range $sub 0 96]...
        }
        set parsed [lindex [::mime::parseaddress $frm] 0]
        set name [dict getdef $parsed friendly $frm]
        set addr [dict getdef $parsed address $frm]
        set dat [clock format $tim -format {%d %b %y}]

        # If we came here from a previous thread, select that,
        # otherwise select the first thread with new posts.
        set id ""
        set tail ""
        if {$new_posts} {
            if {$looking_for_new} {
                set looking_for_new 0
                set id " id='sel'"
            }
            set tail "/0"
        }
        if {$replies} {
            html "<tr class='rep'>"
        } elseif {$new_posts} {
            html "<tr class='new'>"
        } else {
            html "<tr>"
        }
        if {$start_num == $prev_thread} {
            set id " id='sel'"
        }
        html "<td><a$id href=$start_num$tail>[enpre1 $sub]</a></td>"
	html "<td>[enpre1 $name]"
        if {[dict exists $::Faces $addr]} {
            html " <img src='/face/[::wibbly::enhex $addr].png' width='20' align='top' style='float: right'>\n"
        }
	html "</td><td>$dat</td><td align='right'>$thread_posts</td><td align='right'>$new_posts</td></tr>\n"
    }
    html "</tbody>\n</table>\n"

    if {[llength $threads] == 0} {html {<h3>No posts found.<h3/>}}
    if {$blocked} {
        html "<em>$blocked posts blocked.</em>\n"
    }
    html "<form action='/' method='post' style='display: inline'>"

    set posts [expr {[llength $hdrs] / 2}]
    if {$posts >= $::postbatch} {
        html {<input type=submit value='Older Posts' class='but' }
        html "formaction='/$group/older/[incr older]' />\n"
    }

    html "</form>\n"

    return $html
}

# Update number of the last article when user previously read this group
proc update_last {urec group last} {
    # The ugrp record for a user is a map from each group read to
    # the last article present when this user last read the group.
    # Article numbers after the ugrp old_last value will be considered new.
    # If the ugrp record does not already have a new_last value, set it.
    lassign $urec user can_post params ugrps
    set ugrp [dict getdef $ugrps $group 0]
    lassign $ugrp old_last new_last
    if {$new_last eq {} && $last ne {}} {
        redis hset "ugrp $user" $group [list $old_last $last]
    }
}

# Reverse the display order of threads in a group
proc reverse_group {sock urec group} {
    lassign $urec user can_post params

    set reverse [dict get $params rev]
    set reverse [expr {$reverse==0 ? 1 : 0}]
    dict set params rev $reverse

    userdb eval {UPDATE users SET params = $params WHERE num = $user}
    clearThreadinfo $user
    $sock redirect /$group
}

proc group_msgid {sock group msgid} {
    get nh grup $group
    lassign [groupstat $group] desc status grpid
    set dat [overdb eval {SELECT dat FROM over WHERE grpid==$grpid and msgid==$msgid}]
    if {$dat ne {}} {
        $sock redirect /$group/$dat
    } else {
        $sock errorResponse 404 "Sorry, can't find that right now :-("
    }
}

# Show one discussion thread
proc show_thread {urec group start target insearch} {

    # Show the thread structure and posters for this discussion thread
    lassign $urec user can_post params ugrps
    set fail {<h3>Thread not found</h3>}

    # get the block of headers containing the thread start
    set older 0
    GetStash u$user.$group older
    set threadinfo [cacheThreadinfo $urec $group $older 0]
    if {! [dict exists $threadinfo hdrs $start]} {
        set threadinfo [cacheThreadinfo $urec $group 0 $start]
    }
    dict with threadinfo {}
    if {[dict size $hdrs] == 0} {return $fail}
    if {$threads eq ""} {return $fail}

    # look for the thread identified by $start
    set found 0
    set next_thread 0
    set prev_thread 0
    set nextnew_thread 0
    foreach {num thr} $threads {thread_posts new_posts replies} $threadcounts {
        if {$found && !$next_thread} {
            set next_thread $num
        }
        if {$found && $new_posts} {
            set nextnew_thread $num
	    break
        }
        if {$num == $start} {
            set found 1
            set thread $thr
            if {$target==0 && $new_posts==0} {set target $start}
        }
        if {! $found} {
            set prev_thread $num
        }
    }
    if {! $found} {
        if {$target==0} {set target $start}
        set prev_thread 0
        # last-ditch attempt to find thread by working backwards
        foreach {num thr} $threads {
            if {[lsearch -stride 2 -integer $thr $target] != -1} {
                set found 1
                set thread $thr
                break
            }
        }
    }
    if {! $found} {return $fail}

    # find target and previous articles
    set prev 0
    set pv 0
    foreach {num indent} $thread {
        set new [expr {$num > $old_last && [check_xnew $urec $num $hdrs]}]
        if {$new && $target == 0} {set target $num}
        lappend nns $new $num
	if {$num == $target} {set pv $prev}
        set prev $num
    }
    # for the target article, find the next and next-new articles
    set nx 0
    set nn 0
    foreach {num new} [lreverse $nns] {
        if {$num == $target} break
        set nx $num
        if {$new} {set nn $num}
    }
    # prefetch the target and linked articles
    foreach num [list $target $nn $nx $pv] {
        if {$num} {prefetch nh art $group $num}
    }

    dict with params {}

    html "<head><style type='text/css'>
    a:link {color: blue;}
    a:visited {color: black;}
    a:active {color: red;}
    #sel {color: $sel_fg; background-color: $sel_bg}
    .r {border-right:solid 3px}
    .rb {border-right:solid 3px; border-bottom:solid 3px}
    .rbl {border: solid 3px; border-top: 0}
    .new {color: $new_fg; background-color: $new_bg}
    .rep {color: $rep_fg; background-color: $rep_bg}
    .sel {color: $sel_fg; background-color: $sel_bg}
    col+col {width: 6px}
</style></head>"

    html {
<body onload='setup();'>
<script type='text/javascript'>
function setup() {
	//console.log('IN LIST SETUP');
	const target = document.querySelector('.sel');
	if (target) { target.scrollIntoView({block: 'center'}); }
}
</script>
    }
    set srch [expr {$insearch ? "/search" : ""}]
    html "<base href='/$group$srch/$start/0' target='_top' />\n"

    html {
<table style='table-layout: fixed; width:100%; border-collapse:collapse' >
}
    set thread_sub {}
    set indent 0
    set prev_ind $indent
    foreach {num indent} $thread {
        if {$indent < $prev_ind} {
            html {<tr style='height:6px'>} \
	        "<td colspan='[expr {max(30-1-$indent,1)}]' class='rb'></td>" \
	        [string repeat {<td class='r'></td>} [expr {$indent+1}]] "</tr>\n"
	}

        set frag " id='a$num'"
        set clas rbl
        if {$num == $target} {
            append clas { sel}
        }
        if {$num > $old_last && [check_xnew $urec $num $hdrs]} {
            if {$num in $reply_nums} {
                append clas { rep}
            } else {
                append clas { new}
            }
        }
        if {$prev_ind==0} {
	    append frag " style='border: solid 3px'"
        }
        html "<tr><td$frag colspan='[expr {30-$indent}]' class='$clas' >"

        lassign [dict get $hdrs $num] prev sub frm tim id
        if {$num == $target} {
            set thread_sub [encoding convertfrom $sub]
	}
        set frm [encoding convertfrom $frm]
        set parsed [lindex [::mime::parseaddress $frm] 0]
        set name [dict getdef $parsed friendly $frm]
        set addr [dict getdef $parsed address $frm]
        set dat [clock format $tim -format {%d %b %y}]
        html "<span style='float: right'>$dat</span>"
        html "<a href='$num'>[enpre1 $name]</a>"
        if {[dict exists $::Faces $addr]} {
            html "<img src='/face/[::wibbly::enhex $addr].png' width='20' hspace='5' align='top' style='float: right'>\n"
        }

        html {</td>
	} [string repeat {<td class='r'></td>} $indent] {</tr>}

        set prev_ind $indent
    }
    html {</table>}

    html {
    <form action='/' method='post' style='display: inline' target='_top'>}
    if {$insearch} {
	set nums {}
        GetStash s$user.$group nums
	set pos [lsearch -exact $nums $target]
	set next_res [expr {$pos<0 ? {} : [lindex $nums $pos+1]}]
	set prev_res [expr {$pos<0 ? {} : [lindex $nums $pos-1]}]

        html "\n<input type=submit value='Next Search Result' class='bbut' "
        if {$next_res ne {}} {
            html "formaction='/$group/search/$next_res' />"
        } else {
            html "disabled='disabled' />"
        }
        html "\n<input type=submit value='Previous Search Result' class='bbut' "
        if {$prev_res ne {}} {
            html "formaction='/$group/search/$prev_res' />"
        } else {
            html "disabled='disabled' />"
        }
        html "\n<input type=submit value='Back to Search results' class='bbut' "
        html "formaction='/$group/search/list' />"
    } else {
        html "\n<input type=submit value='Next Thread' class='bbut' "
        if {$next_thread} {
            html "formaction='/$group/$next_thread' />"
        } else {
            html "disabled='disabled' />"
        }
        html "\n<input type=submit value='Previous' class='bbut' "
        if {$prev_thread} {
            html "formaction='/$group/$prev_thread' />"
        } else {
            html "disabled='disabled' />"
        }
        html "\n<input id='nn' type=submit value='Next with New Posts \U01F1F3' class='bbut' "
        if {$nextnew_thread} {
            html "formaction='/$group/$nextnew_thread/0' />"
        } else {
            html "disabled='disabled' />"
        }
    }
    html {</form></body>}
    set list_html $html

    page_title "$thread_sub - $group"
    set html "<a id='up' href='/$group' style='font-size: x-large'>$group</a>:"
    html "<span style='font-size: x-large'> [enpre1 $thread_sub]</span>\n"

    html {<iframe style='position:fixed; left:0%; bottom:0%; height:80%; width:30%' }
    html "name='list' srcdoc=\"[enpre2 $list_html]\"></iframe>\n"

    set thread_details [list $thread $target $nx $pv $nn]
    html {<iframe style='position:fixed; right:0%; bottom:0%; height:80%; width:69%' }
    set art_html [thread_arts $urec $group $thread_details $start]
    html "name='art' srcdoc=\"[enpre2 $art_html]\"></iframe>\n"

    return $html
}

# The following *_xnew procs track which posts should not be counted
# as new because they are cross-posted to a group already read.
proc check_xnew {urec num hdrs} {
    lassign [dict get $hdrs $num] prev sub frm dat msgid xgrpids
    tailcall check2_xnew $urec $num $msgid $xgrpids 1
}

proc check2_xnew {urec num msgid xgrpids {update 0}} {
    lassign $urec user can_post params ugrps
    set new 1
    foreach xgrpid $xgrpids {
        set xgroup [id2group $xgrpid]
        if {! [dict exists $ugrps $xgroup]} continue
        if {[lindex [dict get $ugrps $xgroup] 0] >= $num} {set new 0}
        if {$update} {dict set ::XN $user $xgrpid $msgid [clock seconds]}
    }
    return $new
}

proc count_xnew {user group} {
    lassign [groupstat $group] desc status grpid
    return [dict size [dict getdef $::XN $user $grpid {}]]
}

proc clear_xnew {user group} {
    lassign [groupstat $group] desc status grpid
    if {[dict exists $::XN $user]} {
        dict unset ::XN $user $grpid
    }
}
set XN [dict create]

# Adapted from Wibble:
# Encode for HTML <pre> by substituting angle brackets and ampersands.
proc enpre1 {str} {
    string map {< &lt; > &gt; & &amp; \" &quot; \r "" ' &#39;} $str
}
# Extra quoting step needed for srcdoc:
proc enpre2 {str} {
    string map {& &amp; \" &quot;} $str
}

# Generate the display of one or more articles - to be put in an iframe
proc thread_arts {urec group thread_details start} {
    lassign $urec user can_post params
    dict with params {}

    set linx [lassign $thread_details thread target]
    if {$thread == 0} return

    html "<head><style type='text/css'>
    body {color: $gen_fg; background-color: $gen_bg}
    .quot {color: $quo_fg; background-color: $quo_bg}
</style></head>"
    html {
<body onload='setup();'>
<script type='text/javascript'>
function keyDown(event) {
	//console.log('keyDown', event);
	if (event.altKey || event.ctrlKey || event.metaKey) {return;}

	const me = new MouseEvent('click');
        const keyMap = { '+': 'nx',
                         '-': 'pv',
                         'Enter': 'nn',
                         'm': 'mu',
                         'w': 'rf',
                         'r': 'ro',
                         'a': 'ap',
                         'v': 'vs' };
        const buttonId = keyMap[event.key];
        if (buttonId) {
            document.getElementById(buttonId).dispatchEvent(me);
        } else {
		if (event.key == 'n') {
			let listDoc = window.top.frames['list'].document;
			listDoc.getElementById('nn').dispatchEvent(me);
		} else if (event.key == 'Escape') {
			let topDoc = window.top.document;
			topDoc.getElementById('up').dispatchEvent(me);
		}
        }
}
window.scrolled = 0;
function scrolling(event) {
	//console.log('scrolling', event);
	if (! window.scrolled) {
		window.scrolled = 1;
		return;
	}
	const arts = document.getElementsByClassName('art');
	const art = Array.prototype.find.call(arts, (art) => art.getBoundingClientRect().bottom >= 0);
	let listDoc = window.top.frames['list'].document;
	const oldArt = listDoc.querySelector('.sel');
	const newArt = listDoc.getElementById(art.id);
	if (oldArt==newArt) return;
	if (oldArt) {
		oldArt.classList.remove('sel');
	}
	if (newArt) {
		newArt.classList.add('sel');
		newArt.scrollIntoView({block: 'center'});
	}
}
async function doShare(event) {
	//console.log('doShare', event);
	let data = event.target.dataset;
	let shareData = {
		title: data.title,
		text: data.subject,
		url: data.link
	};
	try {
		await navigator.share(shareData);
		//console.log('shared successfully');
	} catch (err) {
		console.log('Sharing Error:', err);
	}
}
function setup() {
	//console.log('IN ART SETUP');
	window.focus();
	window.addEventListener('keydown', keyDown);

	let target = document.querySelector('.target');
	if (target) { target.scrollIntoView(); }

	window.addEventListener('scroll', scrolling);

        let shareButton = document.getElementById('sh');
	if (navigator.canShare) {
        	shareButton.disabled=false;
        	shareButton.addEventListener('click', doShare);
	}
}
</script>
    }

    if {$apt} {
        html [show_thread_arts $urec $group $thread $target $start]
        redis zincrby groupreads 20 $group
    } else {
        html [get_article $urec $group $target $start $linx $target]
        redis zincrby groupreads 10 $group
    }

    html "\n</body>"
    return $html
}

proc show_thread_arts {urec group thread target start} {
    foreach {num indent} $thread {
        prefetch nh art $group $num
        set lastnum $num
    }
    foreach {num indent} $thread {
        set clas art
        if {$num==$target} {append clas " target"}
        html "\n<div class='$clas' id='a$num' "
        if {$num==$lastnum} {html "style='min-height:100vh'"}
        html ">"
        html [get_article $urec $group $num $start {} $target] <hr/>
        html "</div>"
    }
    return $html
}

# Generate an article display
proc get_article {urec group num thr linx target} {
    if {[catch {get nh art $group $num} art]} {
        return "ARTICLE NOT FOUND: [enpre1 $art]"
    }
    lassign $urec user can_post params
    set rot13 0
    GetStash r$user.$group.$num rot13
    dict set params r13 $rot13

    lassign [parse_article $art] headers body
    html [show_article $user $params $headers $body $group]
    html [show_art_foot $user $can_post $params $group $num $thr $linx $headers $target]
    return $html
}

# Format an article for display
proc show_article {user params headers body {group {}}} {
    if {$headers eq {}} {
        html {FAILED TO PARSE ARTICLE:<br/><hr/>}
        html "<pre>\n[enpre1 $body]\n</pre>\n"
        return $html
    }
    set markup [dict get $params mup]
    set reflow [dict get $params flo]
    set rot13 [dict get $params r13]

    set from [dict getdef $headers from {}]
    set parsed [lindex [::mime::parseaddress $from] 0]
    set addr [dict getdef $parsed address $from]
    if {$addr ne {}} {
        if {[dict exists $headers face]} {
            # see spec at https://quimby.gnus.org/circus/face/
            set facedata [dict get $headers face]
            dict set ::Faces $addr [binary decode base64 $facedata]
            html "<img src='/face/[::wibbly::enhex $addr].png' alt='Face' style='float:right'>\n"
        } elseif {[dict exists $headers x-face]} {
            set facedata [dict get $headers x-face]
            dict set ::Faces $addr {}
	    if {[redis hset faces $addr $facedata]} {
                prefetch nh face $facedata
            }
            html "<img src='/face/[::wibbly::enhex $addr].png' alt='X-Face' style='float:right'>\n"
        }
    }
    set msgid [dict get $headers message-id]
    foreach hdr {from newsgroups subject date} {
        set field($hdr) [dict getdef $headers $hdr {}]
        html "<em>[string totitle $hdr]: "
        if {$hdr eq "newsgroups"} {
            set grplinx {}
            foreach grp [split $field($hdr) ,] {
                set grp [string trim $grp]
                if {$grp eq $group} {
                    lappend grplinx $grp
                } else {
                    lappend grplinx "<a href='[local_url $grp/$msgid]' target='_top'>[enpre1 $grp]</a>"
                }
            }
            html "[join $grplinx ,]</em><br/>\n"
        } else {
            catch {set field($hdr) [::mime::field_decode $field($hdr)]}
            html "[enpre1 $field($hdr)]</em><br/>\n"
        }
    }
    #html "<br/>\n"
    if {! $reflow} {html "<pre>\n"}
    set in_quote 0
    foreach line $body {
        if {[string index $line 0] eq {>}} {
	    if {! $in_quote} {html {<div class='quot'>}} 
	    set in_quote 1
	} else {
	    if {$in_quote} {html {</div>}} 
	    set in_quote 0
	}
        if {$rot13} {
            set line [rot13 $line]
	}
        html "[markup_art_line $markup $line]\n"

        if {$reflow} {
            html "<br/>"
        }
    }
    if {! $reflow} {html "</pre>\n"}
    return $html
}

# Convert one article line to html
# (might I be overthinking this?)
proc markup_art_line {markup line} {
    # First tokenise line into a list of triples:
    # text before the token, token type, text of the token.
    # Token types are url, news-msgid, begin-emphasis, end-emphasis.
    set url_re {([[:alnum:]\-+]+://[[:alnum:]\-;,/?:@&=+$_.!~*()#%]+)}
    set news_re {(<[[:graph:]]+@[[:alnum:]\-\.]+>)}
    set begin_emp_re {(?:(?:\A|\s|[[:punct:]])([*/_]+)(?=[[:alnum:]]))}
    set end_emp_re {(?:[[:alnum:]]([*/_]+)(?:\Z|\s|[[:punct:]]))}
    set re "$url_re|$news_re"
    set matches {all url news}
    set be -1; set ee -1
    if {$markup} {
        append re "|$begin_emp_re|$end_emp_re"
        lappend matches be ee
    }
    set indices [regexp -indices -all -inline -- $re $line]
    set start 0
    set tokens {}
    foreach $matches $indices {
        if {[lindex $url 0] > -1} {
            set tok u
	    lassign $url t0 t1
	} elseif {[lindex $news 0] > -1} {
            set tok n
	    lassign $news t0 t1
	} elseif {[lindex $be 0] > -1} {
            set tok b
	    lassign $be t0 t1
	} elseif {[lindex $ee 0] > -1} {
            set tok e
	    lassign $ee t0 t1
	}
	# hack for URLs enclosed in ()
	if {$tok eq "u" && [string index $line $t0-1] eq "("} {
            set close [string last ) $line $t1]
            if {$close > $t0} {
                set t1 [expr {$close - 1}]
            }
        }
        set pre_txt [string range $line $start $t0-1]
        set tok_txt [string range $line $t0 $t1]
        set start [expr {$t1 + 1}]
	# Block javascript URLs
	if {$tok eq "u" && [string match -nocase javascript* $tok_txt]} {set tok x}
        lappend tokens $pre_txt $tok $tok_txt
    }
    lappend tokens [string range $line $start end] 0 {}

    return [markup_art_tokens $tokens]
}

array set em_start {
    / {<em>}
    * {<strong>}
    _ {<span style='text-decoration: underline'>}
}
array set em_end {
    / {</em>}
    * {</strong>}
    _ {</span>}
}

# Process a tokenised line (or part), generating html.
# Make URLs clickable, do emphasis with /*_ ,
# *stuff* => bold, /stuff/ => italic, _stuff_ => underlined.
proc markup_art_tokens tokens {
    html {}
    set ems {}
    while {[llength $tokens]} {
        set tokens [lassign $tokens pre_txt tok tok_txt]

        html [enpre1 $pre_txt]

        switch $tok {
            u { html "<a href='[enpre1 $tok_txt]' target='_blank'>[enpre1 $tok_txt]</a>" }
            n { html "<a href='/[enpre1 $tok_txt]' target='_blank'>[enpre1 $tok_txt]</a>" }
            b { foreach t [split $tok_txt {}] {
                    if {$t ni $ems} {
                        lappend ems $t
                        html $::em_start($t)
              } } }
            e { foreach t [split $tok_txt {}] {
                    if {$t eq [lindex $ems end]} {
                        lpop ems
                        html $::em_end($t)
              } } }

            x { html [enpre1 $tok_txt] }
        }
    }
    # Close any unterminated emphasis
    foreach t [lreverse $ems] {html $::em_end($t)}
    return $html
}

# generate the buttons to show under an article
proc show_art_foot {user can_post params group num thr linx headers target} {
    set from [dict getdef $headers from {}]
    set parsed [lindex [::mime::parseaddress $from] 0]
    set name [dict getdef $parsed friendly {}]
    set addr [dict getdef $parsed address {}]
    set markup [dict get $params mup]
    set reflow [dict get $params flo]
    set rot13 [dict get $params r13]
    set allthr [dict get $params apt]
    lassign [groupstat $group] desc status
    set msgid [dict getdef $headers message-id {}]
    set sub [dict getdef $headers subject {}]

    html {
    <form action='/' method='post' target='_top' style='display: inline'>}

    if {$linx ne {}} {
        lassign $linx nx pv nn
        html "\n<input id='nx' type=submit value='Next Article \U2795' class='bbut' "
        if {$nx} {
            html "formaction='/$group/$thr/$nx' />"
        } else {
            html "disabled='disabled' />"
        }
        html "\n<input id='pv' type=submit value='Previous \U2796' class='bbut' "
        if {$pv} {
            html "formaction='/$group/$thr/$pv' />"
        } else {
            html "disabled='disabled' />"
        }
        #html "\n<input id='nn' type=submit value='Next New \U23CE' class='bbut' "
        html "\n<input id='nn' type=submit value='Next New \U21A9' class='bbut' "
        if {$nn} {
            html "formaction='/$group/$thr/$nn' />"
        } else {
            html "disabled='disabled' />"
        }
    }

    html "\n<input type=submit value='\U01F4DD Post Reply' class='bbut' "
    if {$can_post && $status ne "x"} {
        html "formaction='/$group/$num/post' />"
    } else {
        html "disabled='disabled' />"
    }
    html "\n<input type=submit value='\U01F6AB Block Poster' class='bbut' "
    if {$addr ne {}} {
        html "formaction='/do_block' formtarget='_self' />"
    } else {
        html "disabled='disabled' />"
    }
    tmpl html {<input type='hidden' name='name' value='[enpre1 $name]' />
    <input type='hidden' name='address' value='[enpre1 $addr]' />
    <input type='hidden' name='group' value='$group' />
    <input type='hidden' name='num' value='$num' />
    <input type='hidden' name='thr' value='$thr' />
    }
    set idvs [expr {$num==$target ? "id='vs'" : ""}]
    tmpl html {<input $idvs type=submit value='View Source \U01F1FB' formaction='/$group/$num/raw' formtarget='viewsource' class='bbut' />

    <input id='mu' type=submit value='[tick $markup] Markup \U01F1F2' formaction='/markup' class='bbut' />
    <input id='rf' type=submit value='[tick $reflow] Wrap \U01F1FC' formaction='/reflow' />
    <input id='ro' type=submit value='[tick $rot13] Rot13 \U01F1F7' formaction='/rot13' />
    <input id='ap' type=submit value='[tick $allthr] All Posts \U01F1E6' formaction='/allthr' />
    <button id='sh' type='button' disabled='disabled' data-link='https://$::this_site/[::wibbly::enhex $msgid]' data-subject='[enpre1 $sub]' data-title='$group Posting'>\U290A Share</button>
    <a href='/[::wibbly::enhex $msgid]' target='_blank'>Permalink</a>
    </form>
    }
}

proc tick setting {
    expr {$setting ? "\U2705" : "\U274E"}
}

# Show a single article in raw unprocessed form
proc show_article_raw {sock group num} {
    set art [get nh art $group $num]
    html "<pre>\n[enpre1 $art]\n</pre>\n"
    $sock htmlResponse $html
}

# create rot13 map on startup
binary scan A c A
binary scan a c a
set ins [lseq 0 25]
set outs [concat [lseq 13 25] [lseq 0 12]]
foreach i $ins o $outs {
    foreach b [list $A $a] {
        foreach c [list $i $o] {
            lappend rot13map [binary format c [expr {$b + $c}]]
        }
    }
}
proc rot13 text {
    string map $::rot13map $text
}

# Switch a binary user preference on/off
proc toggle_pref {urec sock pref} {
    lassign $urec user can_post params

    set value [dict get $params $pref]
    set value [expr {$value==1 ? 0 : 1}]
    dict set params $pref $value

    userdb eval {UPDATE users SET params = $params WHERE num = $user}

    set referer [$sock getHeader referer]
    if {$referer eq {}} {set referer /}
    $sock redirect $referer
}

# Switch the rot13 setting on/off, for current article only
proc toggle_rot13 {urec sock} {
    lassign $urec user can_post params

    set missing [GetQuery $sock group num]
    if {[llength $missing] || [groupstat $group] eq {} || ! [string is integer -strict $num]} {
        $sock errorResponse 400
        return
    }
    set rot13 0
    GetStash r$user.$group.$num rot13
    set rot13 [expr {$rot13==1 ? 0 : 1}]
    PutStash r$user.$group.$num rot13

    set referer [$sock getHeader referer]
    if {$referer eq {}} {set referer /}
    $sock redirect $referer
}


# Show block confirm/cancel page
proc do_block sock {
    set missing [GetQuery $sock name address group num]
    if {[llength $missing]} {return "<h3>Missing fields: $missing.</h3>"}

    tmpl html {<h3>Block User '[enpre1 $name]'</h3>
    Proceeding will hide all messages from address '[enpre1 $address]'
    <br/><br/>
    <form action='/block' method='post'>
    <input type=submit value='Confirm Block' class='bbut' />
    <input type=submit value='Cancel' formaction='[local_url $group/$num]' formtarget='_top' class='bbut' />
    <input type='hidden' name='address' value='[enpre1 $address]' />
    </form>}
    $sock htmlResponse $html
}

# Block unwanted address
proc save_block {urec sock} {
    lassign $urec user can_post params
    set address [string trim [$sock getFormdata address]]
    if {$address eq {}} return

    dict lappend params block $address
    userdb eval {UPDATE users SET params = $params WHERE num = $user}

    html "<h3>Address '[enpre1 $address]' Now Blocked</h3>\n"
    html {The list of blocked addresses can be seen and edited by clicking Preferences.<br/>}

    $sock htmlResponse $html
}

set param_defaults {
    rev 1
    mup 0
    flo 0
    block {}
    from {}
    sig {}
    xhdrs {}
    r13 0
    apt 0
    orgn {}
    fupto 0
    narch 0
    face {}
    xface {}
}

set colour_defaults {
    gen_bg #add8e6 gen_fg #000000
    new_bg #ffffe0 new_fg #000000
    rep_bg #ffa500 rep_fg #000000
    sel_bg #90ee90 sel_fg #000000
    quo_bg #e4e4e4 quo_fg #000000
}
    #add8e6 - lightblue
    #ffffe0 - lightyellow
    #ffa500 - orange
    #90ee90 - lightgreen
    #e4e4e4 - lightgrey

# Edit user's preferences
proc edit_prefs {urec sock} {
    lassign $urec user can_post params ugrps
    html {
<script type='text/javascript'>
function setProto(event) {
	navigator.registerProtocolHandler('news', event.target.dataset.handler);
	event.target.style.color = 'green';
}
function setup() {
        let protoButton = document.getElementById('ph');
       	protoButton.disabled=false;
       	protoButton.addEventListener('click', setProto);
}
</script>
    }


    html "<h3>Preferences for [expr {$can_post ? "User " : "Guest "}] $user</h3>\n"

    dict with params {}
    set blocks [join $block \n]

    # ugrp stores User GRouP info
    set groups {}
    foreach {group ugrp} $ugrps {
        lassign $ugrp last
        append groups "$group $last\n"
    }

    html {
<form action='/save_prefs' method='post'>}

    html [pref_label "Groups To Show:<br/>[pref_notes {(Each line lists one group,
    optionally followed by the highest article number when you last read this group.)}]"]
    html "<textarea name='groups' rows='10' cols='50'>[enpre1 $groups]</textarea><br/>"

    html [pref_label {Newest Threads:}]
    html \
"<input type='radio' name='rev' value='0' [expr {$rev ? "" : "checked='checked'"}] />Last " \
"<input type='radio' name='rev' value='1' [expr {$rev ? "checked='checked'" : ""}] />First "

    html [pref_label "<br/>Blocked Posters:<br/>[pref_notes {(Hide posts from these
        addresses, listed one per line.)}]"]
    html {<br/>
<textarea name='blocks' rows='10' cols='50'>} \
    "[enpre1 $blocks]</textarea><br/>"

    html [pref_label {Markup in Posts:}]
    html [off_on_input mup {*words* => bold, /words/ => italic, _words_ => underlined}]

    html [pref_label {Wrap Long Lines:}]
    html [off_on_input flo {use proportional font and wrap long lines}]

    html [pref_label {All Thread Posts:}]
    html [off_on_input apt {show all posts in a thread instead of one at a time}]

    html {<h4>Posting Identity</h4>}
    html [pref_label {Posting Name:}]
    html "<input type='text' name='from' value='[enpre1 $from]' size='50' maxlength='50'/><br/>"
    html [pref_label {Organization:}]
    html "<input type='text' name='orgn' value='[enpre1 $orgn]' size='50' maxlength='50'/><br/>"
    html [pref_label {<br/>Signature:}]
    html "<textarea name='sig' rows='4' cols='70'>[enpre1 $sig]</textarea><br/>"
    html [pref_label {New Password:} 30%]
    html {<input type='password' name='pass1' maxlength='100'/><br/>}
    html [pref_label {Repeat Password:} 30%]
    html {<input type='password' name='pass2' maxlength='100'/>}
    html {<input type=submit value='Change password' formaction='/change_pass' class='bbut' }
    if {! $can_post} {html "disabled='disabled' "}

    html {/> <h4>Optional Posting Headers</h4>}
    html [pref_label {Followup-to:}]
    html [off_on_input fupto {show entry for this header in the posting screen}]
    html [pref_label {X-No-Archive:}]
    html [off_on_input narch {request that your posts should not be archived}]
    set fid [clock milliseconds]
    html [pref_label {X-Face:}]
    if {$xface ne {}} {
        set png [get nh face $xface]
        PutStash tmp_face_$fid png
        html "<img src='/tmp_face/$fid.png' alt='none' align='top' >\n"
    } else {
        html none
    }
    html {<input type=submit value='Set new image' formaction='/pref_xface' class='bbut' />}
    html [pref_notes {(48x48 pixel monochrome icon)}] {<br/>}
    html [pref_label {Face:}]
    if {$face ne {}} {
        set png [binary decode base64 $face]
        incr fid
        PutStash tmp_face_$fid png
        html "<img src='/tmp_face/$fid.png' alt='none' align='top' >\n"
    } else {
        html none
    }
    html {<input type=submit value='Set new image' formaction='/pref_face' class='bbut' />}
    html [pref_notes {(48x48 pixel colour icon)}] {<br/>}

    html [pref_label "Extra Headers:<br/>[pref_notes {(Leave this empty
        unless you really know what you're doing)}]"]
    html "<textarea name='xhdrs' rows='4' cols='80'>[enpre1 $xhdrs]</textarea><br/>"

    html {<h4>Colours</h4>}
    html "<div style='text-align:right; white-space:pre; display:grid; grid-template-columns: repeat(4, max-content)'>"
    html [colour_input {General Background:} gen_bg]
    html [colour_input { Text:} gen_fg]
    html [colour_input {New Posts Background:} new_bg]
    html [colour_input { Text:} new_fg]
    html [colour_input {New Replies Background:} rep_bg]
    html [colour_input { Text:} rep_fg]
    html [colour_input {Selected Post Background:} sel_bg]
    html [colour_input { Text:} sel_fg]
    html [colour_input {Quoted Text Background:} quo_bg]
    html [colour_input { Text:} quo_fg]
    html "</div><br/>"

#printvars gen_bg gen_fg new_bg new_fg rep_bg rep_fg sel_bg sel_fg quo_bg quo_fg
    html {
<br/>
<input type=submit value='Save' class='bbut'/>
<input type=submit value='Cancel' formaction='/' class='bbut' />
<input type=submit value='Reset Colours to Defaults' formaction='/reset_colours' />
<button id='ph' type='button' disabled='disabled' }
    html "data-handler='https://$::this_site/%s'>Handle news: Links</button></form>"
    return $html
}

proc pref_label {text {width 20%}}  {
    return "\n<span style='clear: left; width: $width; float: left'>$text</span>\n"
}

proc pref_notes text {
    return "<em><span style='font-size: small'>$text</span></em>"
}

proc off_on_input {var text} {
    upvar $var val
    html "<input type='radio' name='$var' value='0' "
    html "[expr {$val ? "" : "checked='checked'"}] />Off "
    html "<input type='radio' name='$var' value='1' "
    html "[expr {$val ? "checked='checked'" : ""}] />On "
    html "[pref_notes ($text)] <br/>"
    return $html
}

proc colour_input {text var} {
    upvar $var val
    return "<span style='min-width: 4em'>$text</span><input type='color' name='$var' value='[enpre1 $val]' />"
}

# Save user's preferences
proc save_prefs {urec sock} {
    lassign $urec user can_post params
    set query [$sock getFormdata]
    set newparams {}
    # Check colour settings, save non-default values
    foreach field [dict keys $::colour_defaults] {
        set newval [dict getdef $query $field {}]
        if {$newval eq [dict get $::colour_defaults $field]} continue
        if {[regexp {[^[:alnum:]#]} $newval]} continue
	dict set newparams $field $newval
    }
    # Check general settings, save non-default values
    foreach field [dict keys $::param_defaults] {
        set oldval [dict get $params $field]
        set newval [dict getdef $query $field $oldval]
        if {$newval eq [dict get $::param_defaults $field]} continue
	dict set newparams $field $newval
    }
    foreach field {blocks groups} {
        if {! [dict exists $query $field]} {
	    return "<br/><em>Save failed: '$field' missing.</em>"
	}
        set $field [string trim [dict get $query $field]]
    }
    set blocklist {}
    foreach block [split $blocks \n] {
        set block [string trim $block]
        if {$block ne {}} {lappend blocklist $block}
    }
    dict set newparams block $blocklist
    userdb eval {UPDATE users SET params = $newparams WHERE num = $user}

    set grouplist {}
    foreach groupline [split $groups \n] {
        set groupline [string trim $groupline]

        set group_last_re {^([[:alnum:]_\-\+]+\.[[:alnum:]_\.\-\+]+).*?(\d*)$}
        if {! [regexp $group_last_re $groupline - group last]} continue
	if {! [string is integer -strict $last]} {set last 0}
        lappend grouplist $group $last
    }
    redis del "ugrp $user"
    redis hset "ugrp $user" {*}$grouplist

    clearThreadinfo $user
    html {<h3>Preferences Saved.</h3>}
    html {<form action='/' method='post'>}
    html {<input type=submit value='Continue' style='width: 20%' /></form>}
}

# Reset user's colour preferences to the defaults
proc reset_colours {urec sock} {
    lassign $urec user can_post params
    set params [dict merge $params $::colour_defaults]
    userdb eval {UPDATE users SET params = $params WHERE num = $user}

    $sock redirect /
}

# Set user's Face image
proc pref_face {urec sock fx id} {
    lassign $urec user can_post params ugrps
    set xface [expr {$fx == {x}}]
    set X [expr {$xface ? "X-" : ""}]
    html "<h3>Set ${X}Face image for User $user</h3>\n"

    set note "(This is a 48-pixel-square [expr {$xface ? "monochrome" : "colour"}] \
        image encoded in the ${X}Face header added to your posts. \
        [expr {$xface ? "Many" : "Some"}] Usenet clients \
        will display this when showing your posts.)"

    html "<span style='width: 50%; float: right'>"
    html "[pref_notes $note] </span>"

    set leftish "\n<span style='clear: left; width: 20%; float: left'>"
    html $leftish {Current image:<br/>}
    set data [dict get $params ${fx}face]
    if {$data ne {}} {
	if {$xface} {
            set png [get nh face $data]
	} else {
            set png [binary decode base64 $data]
	}
        set old [clock milliseconds]
        PutStash tmp_face_$old png
        html "<form action='/save_face' method='post' style='display: inline'>\n"
        html "<input type='hidden' name='xface' value='$xface' />\n"
        html "<input type='hidden' name='id' value='0' />\n"
        html "<input type='submit' value='Delete image' class='but'/>\n"
        html "</form></span>"
        html "<img src='/tmp_face/$old.png' alt='none' align='top' >\n"
    } else {
        html {</span> none}
    }

    html {<br/><br/>}
    html {<form ENCtype='multipart/form-data' action='/load_face' method='post' >}
    html $leftish {Set image file:<br/>}
    html "<input type=submit value='Load' class='but'/></span>\n"
    html "<input type=file name='imagefile' accept='image/*'/>\n"
    html "<input type='hidden' name='xface' value='$xface' />\n"
    html "</form><br/><br/>"

    html $leftish {New image:<br/>}
    if {$id eq {}} {
        html {</span> none}
    } else {
        html "<form action='/save_face' method='post' style='display: inline'>\n"
        html "<input type='hidden' name='xface' value='$xface' />\n"
        html "<input type='hidden' name='id' value='$id' />\n"
        html "<input type='submit' value='Use this image' class='but'/></form>\n"
        html "</span><img src='/tmp_face/$id.png' alt='none' align='top' >\n"
    }

    html "<br/><br/><em>or</em><br/>"
    html "<form action='/face_data' method='post' style='display: inline'>\n"
    html $leftish "Enter ${X}Face data:<br/>"
    html "<input type=submit value='Load' class='but'/></span>\n"
    html "<textarea name='data' rows='4' cols='80'></textarea><br/>"
    html "<input type='hidden' name='xface' value='$xface' />\n"
    html "</form>"

    html "<br/><form action='/preferences' method='post'>\n"
    html "<input type='submit' value='Cancel' class='but'/></form>\n"
    return $html
}

proc load_face sock {
    set id [clock milliseconds]
    try { do_load_face $sock $id
    } finally { file delete -- uploads/$id uploads/$id.bw }
}

proc do_load_face {sock id} {
    set formdata [$sock getFormdata]
    set imagefile [dict getdef $formdata imagefile {}]
    if {$imagefile eq {}} {
        $sock errorResponse 404 "Failed to find new face data."
        return
    }
    set out [open "| anytopnm | pamscale -width 48 -height 48 > uploads/$id 2> /dev/null" wb]
    puts -nonewline $out $imagefile
    close $out

    set xface [dict getdef $formdata xface 0]
    if {$xface} {
        exec ppmtopgm uploads/$id | pgmenhance -5 | pamditherbw > uploads/$id.bw 2> /dev/null

        set in [open "| pnmtopng -quiet uploads/$id.bw" rb]
        set png [read $in]
        close $in
        set in [open "| pamtopnm -quiet uploads/$id.bw | pbmtoxbm -quiet | compface" rb]
        set data [read $in]
        close $in
        set data [string trim $data]
        PutStash tmp_face_$id png data
        $sock redirect /pref_xface$id
    } else {

        for {set colours 16} {$colours > 1} {incr colours -1} {
            set in [open "| pnmquant -quiet $colours uploads/$id | pnmtopng" rb]
            set png [read $in]
            close $in
	    if {[string length $png] <= 720} break
        }
        set data [binary encode base64 -maxlen 78 -wrapchar "\n " $png]
        PutStash tmp_face_$id png data
        $sock redirect /pref_face$id
    }
}

proc face_data {urec sock} {
    lassign $urec user can_post params
    set data {}
    GetQuery $sock data xface
    set data [string trim $data]
    if {$data eq {}} {
        $sock errorResponse 400 "Failed to find new face data."
        return
    }
    set id [clock milliseconds]
    if {$xface} {
        set png [get nh face $data]
        PutStash tmp_face_$id png data
        $sock redirect /pref_xface$id
    } else {
        set png [binary decode base64 $data]
        PutStash tmp_face_$id png data
        $sock redirect /pref_face$id
    }
}

proc tmp_face {sock id} {
    $sock cacheMaxAge 300
    GetStash tmp_face_$id png
    if {! [info exists png]} {
        $sock errorResponse 404 "Failed to find new face data."
	return
    }
    $sock dataResponse $png image/png
}

proc save_face {urec sock} {
    lassign $urec user can_post params
    set id none
    GetQuery $sock id xface
    if {$id} {
        GetStash tmp_face_$id data
        if {! [info exists data]} {
            $sock errorResponse 400 "Failed to find new face data for id=$id."
	    return
        }
        if {$xface} {
            dict set params xface $data
        } else {
            dict set params face $data
        }
    } else {
        if {$xface} {
            dict unset params xface
        } else {
            dict unset params face
        }
    }
    userdb eval {UPDATE users SET params = $params WHERE num = $user}
    $sock redirect /preferences
}

# remove group from the user's home page
proc hide_group {sock urec group} {
    lassign $urec user can_post
    redis hdel "ugrp $user" $group
    distcl::forget redis nh counts $user
    $sock redirect /
}

# Implement simple caching using global dicts

# Calculate and cache article thread info which depends on user, group and older
proc cacheThreadinfo {urec group older sought} {
    if {[checkThreadinfoBypass $group]} {
        tailcall calcThreadinfo $urec $group $older $sought
    }
    lassign $urec user can_post params
    set arglist [list $user $group $older $sought]
    set now [clock seconds]
    if {[dict exists $::Threadinfo $arglist]} {
        lassign [dict get $::Threadinfo $arglist] expiry data
        if {$expiry > $now} {
            return $data
        }
    }
    set data [calcThreadinfo $urec $group $older $sought]
    dict set ::Threadinfo $arglist [list [incr now $::tinfoMaxAge] $data]

    # Limit the total number of entries the cache will hold
    if {[dict size $::Threadinfo] > $::tinfoMaxEntries} {
        set first [lindex [dict keys $::Threadinfo] 0]
        dict unset ::Threadinfo $first
    }
    return $data
}

# Calculate article thread info which depends on user, group, older and sought
proc calcThreadinfo {urec group older sought} {
    lassign $urec user can_post params ugrps
    set blocklist [dict get $params block]
    set reverse [dict get $params rev]

    get nh grup $group
    set hdrs [get_hdrs $group $older $sought]

    lassign [get_threads $hdrs $blocklist $user $sought] threads blocked reply_nums
    set threads [lsort -stride 2 -integer $threads]

    lassign [dict getdef $ugrps $group 0] old_last

    set threadcounts {}
    foreach {start_num thread} $threads {
        set thread_posts [expr {[llength $thread] / 2}]
        set new_posts 0
        set replies 0
        foreach {num indent} $thread {
            if {$num > $old_last && [check_xnew $urec $num $hdrs]} {
                incr new_posts
                if {$num in $reply_nums} {incr replies}
            }
        }
        lappend threadcounts $thread_posts $new_posts $replies
    }

    if {$reverse} {
        set rev {}
        foreach {a b} [lreverse $threads] {lappend rev $b $a}
        set threads $rev

        set rev {}
        foreach {a b c} [lreverse $threadcounts] {lappend rev $c $b $a}
        set threadcounts $rev
    }

    set data [list hdrs $hdrs threads $threads blocked $blocked]
    lappend data old_last $old_last threadcounts $threadcounts reply_nums $reply_nums
    return $data
}

proc clearThreadinfo user {
    foreach key [dict keys $::Threadinfo "$user *"] {
        dict unset ::Threadinfo $key
    }
}
set ::Threadinfo [dict create]
set ::ThreadinfoBypass [dict create]

proc bypassThreadinfo {grouplist timeout} {
    set expiry [expr {[clock seconds] + $timeout}]
    foreach group $grouplist {
        dict set ::ThreadinfoBypass $group $expiry
    }
}

proc checkThreadinfoBypass group {
    set now [clock seconds]
    if {[dict exists $::ThreadinfoBypass $group]} {
        if {$now < [dict get $::ThreadinfoBypass $group]} {return 1}
        dict unset ::ThreadinfoBypass $group
    }
    return 0
}

# short-term storage of context-specific data
proc PutStash {context args} {
    foreach var $args {
        upvar $var st[incr n]
        lappend vars $var [set st$n]
    }
    set expiry [expr {[clock seconds] + $::stashMaxAge}]
    dict set ::Stash $context [list $expiry $vars]
}
set Stash [dict create]

proc GetStash {context args} {
    if {[llength $args] == 0} return
    if {! [dict exists $::Stash $context]} {return $args}
    set value [dict get $::Stash $context]
    set stash [lindex $value 1]
    set missing {}
    foreach var $args {
        if {[dict exists $stash $var]} {
            upvar $var var[incr n]
	    set var$n [dict get $stash $var]
	} else {
	    lappend missing $var
	}
    }
    return $missing
}

# Periodically we do Garbage Collection of old/dead cache entries
set stashMaxAge 3600 ;# 1 hour in seconds
set tinfoMaxAge 300 ;# 5 minutes in seconds
set tinfoMaxEntries 100
proc cacheGC {} {
    set now [clock seconds]

    # remove old Stash entries
    dict for {key value} $::Stash {
        if {[lindex $value 0] < $now} {
            dict unset ::Stash $key
        }
    }
    # remove old Threadinfo entries
    dict for {key value} $::Threadinfo {
        if {[lindex $value 0] < $now} {
            dict unset ::Threadinfo $key
        }
    }
}

set cacheGCinterval [expr {5*60*1000}] ;# 5 minutes in ms
after $cacheGCinterval doCacheGC
proc doCacheGC {} {
    #puts "Running cacheGC"
    cacheGC
    after $::cacheGCinterval doCacheGC
}

# Load group statuses, descriptions and grpids into thread-shared value.
proc load_groupstats {} {
    overdb eval {SELECT name,stat,desc,rowid FROM groups} {
        catch {set desc [encoding convertfrom utf-8 $desc]}
        dict set ::Groupstats $name [list $desc $stat $rowid]
        dict set ::Id2Group $rowid $name
        incr ::numgroups
    }
}
after idle load_groupstats

proc groupstat group {
    dict getdef $::Groupstats $group {}
}
proc id2group grpid {
    dict getdef $::Id2Group $grpid {}
}
set Groupstats [dict create]
set Id2Group [dict create]

# Look for specified variables in the request's data.
# If found, set them in the caller's scope.
# Return a list of any not found.
proc GetQuery {sock args} {
    set query [$sock getFormdata]
    set missing {}
    foreach var $args {
        if {[dict exists $query $var]} {
            upvar $var var[incr n]
	    set var$n [dict get $query $var]
	} else {
            if {! [uplevel info exists $var]} {
	        lappend missing $var
            }
	}
    }
    return $missing
}

# Run an article search and show the results
proc show_art_search {sock urec group} {
    lassign $urec user can_post params ugrps
    set subj {}
    set from {}
    set date {}
    set nexttim {}

    # Are there previous parameters we should restore?
    set prev_result 0
    set prev_result_re "/[string map {. \\. + \\+} $group]/search/(\\d*)"
    if {[llength [GetQuery $sock clear]]} {
        if {[regexp $prev_result_re [$sock getHeader referer] - num]} {
            GetStash s$user.$group subj from date
            if {$num ne {}} {set prev_result $num}
        }
        GetQuery $sock subj from date nexttim
    }
    if {! [llength [GetQuery $sock more]]} {
        set tim $nexttim
        set date [clock format $tim -format %Y-%m-%d]
    } elseif {$date eq {}} {
        set tim {}
    } else {
        set tim [clock scan $date -format %Y-%m-%d]
    }

    set allgroups [expr {$group eq "all.all"}]
    if {! $allgroups} {
        lassign [find_hdrs $group $subj $from $tim] more_tim hdrs
    } else {
        lassign [get nh findall $user $subj $from $tim] more_tim hdrs
    }

    tmpl html {
<script type='text/javascript'>
function setup() {
	document.getElementById('sel').focus();
}
</script>

<form action='list' method='post'>
<span style='float: right'>
<input type='submit' value='Search' name='search' class='but' />
<input type='submit' value='Clear' name='clear' class='but' />
</span>
<input type='hidden' name='nexttim' value='$more_tim' />
% if {$allgroups} {
  <h3>Search articles in all my groups for</h3>
  <table><thead> <tr align='left'> <th>Group</th>
% } else {
  <h3>Search <a href='/$group'>$group</a> articles for</h3>
  <table><thead> <tr align='left'>
% }
<th>Subject including</th><th>Author including</th><th>Date up to</th></tr>
<tr align='left'>
% if {$allgroups} {
  <th/>
% }
<th><input type='text' name='subj' size='50' value='[enpre1 $subj]'/></th>
<th><input type='text' name='from' size='30' value='[enpre1 $from]'/></th>
<th><input type='date' name='date' min='1980-01-01' value='[enpre1 $date]'/></th>
</tr>
</thead><tbody>
    }

    set nums {}
    foreach detail $hdrs {
        lassign $detail grpid sub frm num msgid xgrpids
        lappend nums $num
        set sub [encoding convertfrom $sub]
        set frm [encoding convertfrom $frm]
        set dat [clock format $num -format {%d %b %y}]
        lappend xgrpids $grpid
 
        if {[check2_xnew $urec $num $msgid $xgrpids]} {
            html "<tr class='new'>"
        } else {
            html "<tr>"
        }
        set id {}
        if {$num eq $prev_result} {
            set id " id='sel'"
        }
        if {$allgroups} {
            set group [id2group $grpid]
            html "<td>$group</td>"
            set link "/$group/$num"
        } else {
            set link $num
        }
        html "<td><a$id href=$link>[enpre1 $sub]</a></td>"
	html "<td>[enpre1 $frm]</td><td>$dat</td></tr>\n"
    }
    tmpl html {<tr><td/><td/>
% if {$allgroups} {
    <td/>
% }
    <td><input type='submit' value='Earlier Dates' name='more' class='but' 
% if {! $more_tim} {
    disabled='disabled' 
% }
    /></td></tr>
    </tbody></table>
    </form>
% if {[llength $hdrs] == 0} {
    <h3>No Matches Found</h3>
% }
    }
    PutStash s$user.$group subj from date nums

    return $html
}

proc find_hdrs {group sub frm tim} {
    set hdrs {}
    lassign [groupstat $group] desc status grpid

    set sql {SELECT sub,frm,dat,msgid,xgrpids FROM over WHERE grpid==$grpid }
    if {$sub ne {}} {set sub %$sub%; append sql {AND sub LIKE $sub }}
    if {$frm ne {}} {set frm %$frm%; append sql {AND frm LIKE $frm }}
    if {$tim ne {}} {append sql {AND dat <= $tim }}
    append sql {ORDER BY dat DESC}
    append sql " LIMIT $::postbatch"
    overdb eval $sql {
        set sub [convertit $sub]
        set frm [convertit $frm]
        lappend hdrs [list $grpid $sub $frm $dat $msgid $xgrpids]
    }
    set more_dat [expr {[llength $hdrs]==$::postbatch ? [lindex $hdrs end 3] : 0}]
    return [list $more_dat $hdrs]
}

# Show the group charter, if possible
proc show_charter group {
    html "\n<h3>Charter for group <a href='/$group'>$group</a></h3>\n"
    set tail [join [lassign [split $group .] hier] .]

    switch $hier {
        de {set url "https://dana.de/chartas/de.html#$group"}
        it {set url "http://www.news.nic.it/manif/$group.html"}
        fr {set url "https://www.usenet-fr.net/fur/chartes/$tail.html"}
        uk {set url "https://www.usenet.org.uk/$group.html"}

        default {
            set charter [get nh charter $group]
            if {$charter eq {}} {set charter "Unable to retrieve charter."}
            return [html "<pre>[enpre1 $charter]</pre>"]
        }
    }
    html {<iframe style='position:fixed; right:0%; bottom:0%; height:80%; width:100%' }
    html "src='$url'></iframe>\n"
}

# Show the form to write a post
proc compose_new {urec group args} {
    lassign $urec user can_post params
    if {! $can_post} {
        return {<br/><span style='color:red'><em>
            Sorry, you need to register and log in to post.</em></span>}
    }
    set msgs [lassign $args groups subject refs body]
    if {[string trim $groups] eq {}} {set groups $group}
    set grouplist [split $groups ,]

    if {[spam_check $user $body $grouplist]} {
        return "<br/><em>Sorry, you have exceeded the maximum number\
            or volume of posts allowed in one day.</em>"
    }
    if {[catch {moderated $grouplist} moderated]} {
        lappend msgs $moderated
        set moderated 0
    }
    if {$moderated} {
        set wait_until [morphing_check $user $::morph_reserve]
        if {$wait_until} {
        return "<br/><em>Sorry, you need to wait until [clock format $wait_until]\
            before you can post to a moderated group.</em>"
        }
    }

    set from [dict get $params from]
    set fupto [dict get $params fupto]
    set sig [dict get $params sig]
    if {$sig ne {} && [string first "\n-- \r" $body] == -1} {
        append body "\n\n-- \n$sig"
    }
    html "<h3>Create New Article</h3>\n"
    if {[llength $msgs]} {
        set msg [enpre1 [join $msgs <br/>]]
        html "<span style='color:red'><em>$msg</em></span>\n"
    }
    html {
<form action='/post' method='post' target='_top'>
} [form_field From from $from] \
  [form_field Newsgroups groups $groups]
    if {[llength $grouplist] > 1} {
        html {<span style='color:red; font-size: small'><em>Please check
that your message is relevant to all groups in the list above, and remove
any inappropriate groups</em></span><br/>}
    } elseif {[llength $grouplist] == 1 && $groups ne $group} {
        html {<span style='color:red; font-size: small'><em>The poster
you are replying to has requested Followup-To the group above,
please check that this is appropriate</em></span><br/>}
    }
    html [form_field Subject subject $subject]
    if {$fupto} {
        html [form_field Followup-To fupto {}]
    }
    html "<textarea name='body' rows='20' cols='80' wrap='off' style='font-size: large'>[enpre1 $body]</textarea>" \
{<br/>
<input type=submit value='Post' style='width: 10em' />} \
    "<input type=submit value='Quit' style='width: 10em' formaction='[local_url $group]'/>" \
    "<input type='hidden' name='group' value='[enpre1 $group]' />\n" \
    "<input type='hidden' name='refs' value='[enpre1 $refs]' /></form>\n"

    return $html
}

proc form_field {label name value} {
    html "<span style='font-size: large; width: 10em; float: left'>${label}:</span>"
    html "<input type='text' name='$name' size='70' value='[enpre1 $value]' />"
    html "<br clear='left'/>\n"
}

# Start a post in reply to an existing article
proc compose_reply {urec group num} {
    if {[catch {get nh art $group $num} art]} {
        return {Post not found.}
    }
    lassign [parse_article $art] headers old_body
    if {$headers eq {}} {
        return {Post not found.}
    }
    set groups [string trim [dict getdef $headers followup-to {}]]
    if {$groups eq {} || [string equal -nocase $groups poster]} {
        set groups [dict getdef $headers newsgroups $group]
    }
    set old_sub [dict getdef $headers subject {}]
    catch {set old_sub [::mime::field_decode $old_sub]}
    if {[string match -nocase {Re: *} $old_sub]} {
        set subject $old_sub
    } else {
        set subject "Re: $old_sub"
    }
    set msgid [dict get $headers message-id]
    set refs [string trim "[dict getdef $headers references {}] $msgid"]

    set body "[dict getdef $headers from Someone] posted:\n\n"
    foreach line $old_body {
        if {$line eq "-- "} break
        append body "> $line\n"
    }
    tailcall compose_new $urec $group $groups $subject $refs $body
}

# Send a new post to the news server
proc do_post {urec sock} {
    lassign $urec user can_post params
    if {! $can_post} {
        return {<br/><span style='color:red'><em>
            Sorry, you need to register and log in to post.</em></span>}
    }
    
    set fupto {}
    set missing [GetQuery $sock from subject group groups refs body fupto]
    if {[llength $missing]} {
        return "<br/><em>Post failed: '$missing' missing.</em>"
    }
    set body [string map [list "\r\n" "\n"] $body]
    foreach field {from subject groups body} {
        if {[set $field] eq ""} {
            set msg "[string totitle $field] cannot be empty"
            tailcall compose_new $urec $group $groups $subject $refs $body $msg
        }
    }
    set grouplist [split $groups ,]
    if {[catch {moderated $grouplist} moderated]} {
        tailcall compose_new $urec $group {} $subject $refs $body $moderated
    }
    if {$moderated} {
        set wait_until [morphing_check $user $::morph_timeout]
        if {$wait_until} {
            return "<br/><em>Sorry, you need to wait until [clock format $wait_until]\
                before you can post to a moderated group.</em>"
        }
    }
    set uucp [expr {! $moderated}]

    if {[spam_check $user $body $grouplist 1]} {
        return "<br/><em>Sorry, this post would exceed the maximum number\
            or volume of posts allowed in one day.</em>"
    }

    set txt ""
    if $uucp {append txt "Path: $::this_site!.POSTED!not-for-mail\n"}
    regsub -all {<.*>|[[:cntrl:]]+} $from {} from
    append txt "From: [field_encode $from] <user$user@$::this_site.invalid>\n"
    add_hdr txt Newsgroups $groups
    add_hdr txt Subject [field_encode $subject]
    if {$refs ne {}} {
        add_hdr txt References $refs
    }
    if {$fupto ne {}} {
        add_hdr txt Followup-To $fupto
    }
    set date [clock format [clock seconds] -format {%a, %d %b %Y %H:%M:%S GMT} -gmt true]
    append txt "Date: $date\n"
    append txt {Mime-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 8bit
}
    if $uucp {
        append txt "Message-ID: <[clock seconds]-$user@$::this_site>\n"
        append txt "Injection-Info: $::this_site; mail-complaints-to=\"$::admin_email\"; posting-account=user$user\n"
        append txt "Injection-Date: $date\n"
    }
    append txt "User-Agent: Newsgrouper/$::ng_version\n"

    if {[dict get $params narch]} {append txt "X-No-Archive: yes\n"}
    if {[dict get $params orgn] ne {}} {
        add_hdr txt Organization [dict get $params orgn]
    }
    if {[dict get $params xface] ne {}} {
        add_hdr txt X-Face [dict get $params xface]
    }
    if {[dict get $params face] ne {}} {
        add_hdr txt Face [dict get $params face]
    }
    set xhdrs [dict get $params xhdrs]
    set xhdrs [string trim [string map [list "\r\n" "\n"] $xhdrs]]
    if {$xhdrs ne {}} {append txt $xhdrs "\n"}

    append txt "\n" $body
    html "<h3>Group <a href='[local_url $group]'>[enpre1 $group]</a></h3>\n"
    if $uucp {
        html "[send_uucp $txt]\n"
    } else {
        html "[send_nntp $txt]\n"
    }
    bypassThreadinfo $grouplist 300 ;# disable caching for next 5 min
    if {$from ne [dict get $params from]} {
        dict set params from $from
        userdb eval {UPDATE users SET params = $params WHERE num = $user}
    }
    return $html
}

# Encode a header field with the shorter of base64 or quoted-printable
proc field_encode text {
    if {[string is ascii $text]} {return $text}
    if {[catch {
        set encB [::mime::word_encode utf-8 base64 $text -charset_encoded 0]
        set encQ [::mime::word_encode utf-8 quoted-printable $text -charset_encoded 0]
    }]} {return $text}

    if {[string length $encB] < [string length $encQ]} {
        return $encB
    } else {
        return $encQ
    }
}

proc add_hdr {txt name val} {
    upvar $txt text
    # Ensure line breaks in the value do not start a new header
    append text "${name}: [regsub -all {[\r\n]+} $val "\n "]\n"
}

#### Data Access Stuff ####

# Return the list of group names and descriptions which match a pattern.
# pattern is the glob-style pattern to look for;
# match_name is whether to match against the group name;
# match_desc is whether to match against the group description.
proc groups_matching {pattern match_name match_desc} {
    set matched {}
    dict for {group status} $::Groupstats {
        set desc [lindex $status 0]
        set match 0
        set fields {}
        if {$match_name} {lappend fields $group}
        if {$match_desc} {lappend fields $desc}
        foreach field $fields {
            if {[string match -nocase $pattern $field]} {
                set match 1
            }
        }
        if {$match} {lappend matched $group $desc}
    }
    return [lsort -stride 2 $matched]
}

# Get the header info for the 500 most recent posts in a group,
# and any older posts they link to. If 'older' is non-zero,
# skip that number of new posts before starting.
proc get_hdrs {group older sought} {
    set ::msgid2num [dict create]
    set ::missing_ref 0
    set hdrs {}
    set rev_hdrs {}
    lassign [groupstat $group] desc status grpid
    set older [expr {$older * $::postbatch}]

    if {$sought} {
        set sql {
WITH RECURSIVE
  ids(id) AS (
    SELECT msgid FROM over WHERE grpid==$grpid AND dat==$sought
    UNION
    SELECT msgid FROM over,ids WHERE grpid==$grpid AND prev=id
    UNION
    SELECT prev FROM over,ids WHERE grpid==$grpid AND msgid=id AND prev!=''
  )}
    } else {
        set sql {
WITH RECURSIVE
  mids(mid) AS (
    SELECT msgid FROM over WHERE grpid==$grpid }
    append sql {ORDER BY dat DESC}
    append sql { LIMIT $::postbatch}
    if {$older} {append sql { OFFSET $older}}
    append sql {),
  ids(id) AS (
    SELECT mid FROM mids
    UNION
    SELECT prev FROM over,ids WHERE grpid==$grpid AND msgid=id AND prev!=''
  )}
    }
    append sql {
SELECT sub,frm,dat,msgid,prev,xgrpids FROM over,ids WHERE grpid==$grpid AND msgid==id
ORDER BY dat DESC
}

    overdb eval $sql {
        dict set ::msgid2num $msgid $dat
        lappend rev_hdrs [list $prev $sub $frm $dat $msgid $xgrpids]
    }
    foreach hdr [lreverse $rev_hdrs] {
        lassign $hdr prev sub frm dat msgid xgrpids

        if {$prev eq {}} {
            set prevnum 0
        } else {
            set prevnum [get_num $prev]
        }

        set sub [convertit $sub]
        set frm [convertit $frm]
        lappend hdrs $dat [list $prevnum $sub $frm $dat $msgid $xgrpids]
    }
    return $hdrs
}

proc get_num msgid {
    if {[dict exists $::msgid2num $msgid]} {
        return [dict get $::msgid2num $msgid]
    }
    set num [incr ::missing_ref -1]
    dict set ::msgid2num $msgid $num
    return $num
}

proc convertit txt {
    if {[catch {encoding convertto $txt} res]} {
        #TODO Fix better?
        return "ENCODING CONVERSION ERROR"
    }
    return $res
}

# Use the 'prev' links in the headers list to build the thread structure.
# While doing this skip all posters the user has blocked.
# If a specific article is sought (returned by a search) we include it
# even if it would normally be blocked.
# Returns a list alternating:
#   - start of thread (article number)
#   - list of articles in the thread and their indentation level.
# Also returns total number of blocked posts,
# and list of replies to current user's posts.
proc get_threads {hdrs blocklist user sought} {
    set blocks 0
    set redirects [dict create]
    set ::followups [dict create]
    set missing_starts [dict create]
    set thread_starts {}
    set threads {}
    set useraddr "user$user@$::this_site.invalid"
    set userposts {}
    set reply_nums {}
    foreach {num detail} $hdrs {
        lassign $detail prev sub frm
        set frm [encoding convertfrom $frm]

        if {[dict exists $redirects $prev]} {
	    set new_prev [dict get $redirects $prev]
	    if {$new_prev == 0} {
	        dict set redirects $prev $num
	    }
	    set prev $new_prev
	}
        set parsed [lindex [::mime::parseaddress $frm] 0]
        set address [dict getdef $parsed address $frm]
        if {$num != $sought && $address in $blocklist} {
	    dict set redirects $num $prev
	    incr blocks
	    continue
	}
        if {$prev < 0} {
	    dict set missing_starts $prev 1
	}
        if {$address eq $useraddr} {
	    lappend userposts $num
	}

        # followups maps each article to the list of its direct replies
        if {$prev} {
	    dict lappend ::followups $prev $num
	    if {$prev in $userposts} {
                lappend reply_nums $num
            }
	} else {
	    lappend thread_starts $num
	}
    }
    set all_starts [concat [dict keys $missing_starts] $thread_starts]

    foreach num $all_starts {
        set ::post_indent {}
        set ::thread_latest 0
        do_thread $num 0
        #lappend threads $::thread_latest $::post_indent
        set start [lindex $::post_indent 0]
        lappend threads $start $::post_indent
    }
    return [list $threads $blocks $reply_nums]
}

# recursively build the structure of one thread into ::post_indent
proc do_thread {num indent} {
    if {$num > $::thread_latest} {set ::thread_latest $num}
    if {$num > 0} {
        lappend ::post_indent $num $indent
    }
    set fups [dict getdef $::followups $num {}]
    incr indent [llength $fups]
    set lastf [lindex $fups end]
    foreach f $fups {
        if {$f != $lastf} {
            do_thread $f [incr indent -1]
        } else {
            tailcall do_thread $f [incr indent -1]
        }
    }
}

# Parse an article from the news server, return a dict of the headers
# and a list of body lines.
proc parse_article {art} {

    # kludge to fix unrecognised encoding
    regsub -all -line {^Content-Transfer-Encoding:\s+8-bit\s*$} $art \
        {Content-Transfer-Encoding: 8bit} art

    if {[catch {::mime::initialize -string $art} mt]} {
        #puts "::mime::initialize FAILED: '$mt'"
        tailcall parse_article_a $art
        #return {}
    }
    if {[catch {::mime::getheader $mt} headers]} {
        puts "::mime::getheader FAILED: '$headers'"
        return [list {} $art]
    }
    # if message is multi-part, use the first part as the body
    set props [::mime::getproperty $mt]
    if {[dict exists $props parts]} {
        lassign [dict get $props parts] bt
    } else {
        set bt $mt
    }

    if {[catch {::mime::getbody $bt -decode} body]} {
        if {[catch {::mime::getbody $bt} body2]} {
            set body "/ERROR \"$body2\" in ::mime::getbody/"
        } else {
            set body "/ERROR \"$body\" while decoding/:\n\n$body2"
        }
    }
    ::mime::finalize $mt
    dict for {name value} $headers {
        dict set lc_headers [string tolower $name] $value
    }
    return [list $lc_headers [split $body \n]]
}

# Attempt to parse an article in the ancient A format
proc parse_article_a art {
    if {[string index $art 0] ne "A"} {return [list {} $art]}
    set body [lassign [split $art \n] id grps from date sub]
    if {[string first $id :] != -1} {return [list {} $art]}
    set headers [dict create from $from newsgroups $grps subject $sub date $date]
    return [list $headers $body]
}

# Get the image for an X-Face header from the nh (newshub) service
proc get_face {sock addr} {
    $sock cacheMaxAge 300
    set png [dict getdef $::Faces $addr {}]
    if {$png ne {}} {
        $sock dataResponse $png image/png
        return
    }
    set facedata [redis hget faces $addr]
    if {$facedata eq "(nil)"} {
        $sock errorResponse 404 "Failed to find face data."
        return
    }
    if {[catch {get nh face $facedata} png]} {
        $sock errorResponse 404 "Failed to decode face data '[enpre1 $png]'."
        return
    }
    dict set ::Faces $addr $png
    $sock dataResponse $png image/png
}
set Faces [dict create]

# Send a new article to the news server using NNTP.
# txt is the whole article.
proc send_nntp txt {
    set txt [encoding convertto $txt]
    if {[catch {get ng post $txt} result]} {
        return "Posting Failed: $result"
    } else {
        return "Posting Succeeded."
    }
}

# Send a new article to the news server using UUCP.
# txt is the whole article.
proc send_uucp txt {
    exec -- /usr/bin/uux - $::uucp_server!rnews << $txt
    return "Posting Sent."
}

# Check whether sending an nntp post now would break the E-S restriction that
# the From header cannot use more than 5 distinct emails in a 24hr period.
# Return 0 if ok, otherwise the unix time when posting will become possible.
proc morphing_check {user timeout} {
    if {$::morph_limit <= 0} {return 0}

    # morphers is a redis sorted set mapping posters to their expiry time.
    # first clear out expired posters
    set now [clock seconds]
    redis zremrangebyscore morphers 0 $now
    
    set num_users [redis zcard morphers]
    set user_prev_time [redis zscore morphers $user]
    if {$user_prev_time eq "(nil)"} {set user_prev_time 0}

    if {$num_users > $::morph_limit ||
        ($num_users == $::morph_limit && ! $user_prev_time)} {
            # return the expiry time of the oldest poster
            set oldest [redis zrange morphers 0 0 withscores]
            return [lindex $oldest 1]
    }

    # ok to proceed
    set new_expiry_time [expr {max($now+$timeout,$user_prev_time)}]
    redis zadd morphers $new_expiry_time $user
    return 0
}
set hour_secs [expr {60*60}];# 1 hour in seconds
set day_secs [expr {60*60*24}];# 24 hours in seconds
set week_secs [expr {$day_secs*7}];# 7 days in seconds
set year_secs [expr {$day_secs*365}];# 365 days in seconds
set hour_ms [expr {$hour_secs*1000}];# 1 hour in milliseconds

set morph_limit 0
#set morph_limit 5
set morph_timeout $day_secs
set morph_reserve [expr {60*15}] ;# 15 minutes in seconds

# Are any of these groups moderated?
proc moderated groups {
    foreach group $groups {
        lassign [groupstat $group] desc status
        if {$status eq {}} {error "Invalid Group: '$group'"}
        if {$status eq "m"} {return 1}
    }
    return 0
}

# enforce a limit on number and volume of posts per day per user
proc spam_check {user body grouplist {update 0}} {
    # get totals for any previous posts by this user today
    set weekday [clock format [clock seconds] -format %w]
    set usp usp$user.$weekday
    lassign [redis get $usp] count volume
    if {$volume eq {}} {
        set count 0
        set volume 0
    }
    # if posting, update their totals
    if {$update} {
        # cross-posts count as multiple posts
        set group_count [llength $grouplist]
        set new_volume [expr {[string length $body] * $group_count}]
        incr count $group_count
        incr volume $new_volume
    }
    # check if they are over one of the limits
    if {$count >= $::spam_max_count || $volume > $::spam_max_volume} {return 1}

    # if posting, save their totals
    if {$update} {
        redis set $usp [list $count $volume] ex $::day_secs
    }
    return 0
}
set spam_max_count 50
set spam_max_volume 100000

# Change user's password
proc change_pass {urec sock} {
    lassign $urec user can_post params

    if {! $can_post} {
        $sock errorResponse 403 {Close but no cigar!}
        return
    }
    set missing [GetQuery $sock pass1 pass2]
    if {[llength $missing] || $pass1 eq {} || $pass1 ne $pass2} {
        $sock errorResponse 400 {Both passwords must be the same and non-empty.}
        return
    }
    set enc_pass [md5crypt::md5crypt $pass1 [md5crypt::salt]]
    userdb eval {UPDATE users SET pass = $enc_pass WHERE num = $user}

    $sock redirect /
}

#### Site Status Stuff ####

if 0 {
# Online Safety Act survey for UK users
proc need_survey {sock urec} {
    lassign $urec user can_post params
    upvar #0 Httpd$sock data
    if {! [info exists data(mime,cf-ipcountry)]} {return 0}
    if {$data(mime,cf-ipcountry) ne "GB"} {return 0}
    if {[redis get "survey $user"] ne "(nil)"} {return 0}
    return 1
}

proc do_survey {sock suffix urec} {
    lassign $urec user can_post params
    if {$suffix eq "skip"} {
        # Skip lasts for one day
        redis set "survey $user" skip ex $::day_secs
        $sock redirect /
        return
    }
    set comment {}
    set missing [GetQuery $sock impact comment]
    if {$suffix eq "survey" && ! [llength $missing]} {
        set data [list $can_post $impact $comment]
        redis set "survey $user" $data
        $sock redirect /
        return
    }
    html [heading $params]
    html {<h3>Survey - UK Online Safety Act</h3>
You are seeing this page because you appear to be connecting from an IP address in the UK.
<p/>
On the 17th of March the UK's new Online Safety Act will start to be enforced.
For more information see
<a href='https://www.ofcom.org.uk/online-safety/' target='_blank'>Ofcom's official site</a>,
<a href='https://onlinesafetyact.co.uk/' target='_blank'>an unofficial guide</a>,
<a href='https://www.theguardian.com/commentisfree/2025/jan/12/note-to-no-10-one-speed-doesnt-fit-all-when-it-comes-to-online-safety' target='_blank'>comment in the Guardian</a>.
<p/>
I am concerned that the requirements of the act may be more than I can reasonably cope with. It appears to have been drafted with very large social media operations in mind, and makes only small concessions to small, non-commercial sites like this one.  Even small sites are required to undertake long and complicated risk assessments, have formal reporting procedures for content which may be illegal under various categories and to remove such content.  Failure to comply can lead to severe penalties.
<p/>
However the act also specifies that a site operator also has "a duty to have particular regard to the importance of protecting users’ right to freedom of expression within the law".
Some cases will be clear, but one can easily imagine cases where one person's freedom of expression conflicts with another's idea of harm. I do not feel at all confident to make such judgements.
<p/>
I could avoid all this trouble by blocking access to this site from UK addresses.  These are about 20% of total users.  So I am asking for feedback on this option.
<p/>
Please rate how blocking access to Newsgrouper from UK IP addresses would affect you:<br/>
<form action='/survey' method='post'>
<input type='radio' name='impact' value='1' />Not Concerned, I can follow Usenet by other means.<br/>
<input type='radio' name='impact' value='2' />An Annoyance, but not the end of the world.<br/>
<input type='radio' name='impact' value='3' />Oh No, that would be a disaster!
<br/><br/>Any comments:<br/>}
    html "<textarea name='comment' rows='5' cols='80'>$comment</textarea><br/>"
    html {
<input type=submit value='Save' class='but' />
<input type=submit value='Skip Today' formaction='/skip' class='but'/>
</form></body>}
    $sock htmlResponse $html
}

# Warn UK user about impending OSA block
proc need_warn {sock urec} {
    lassign $urec user can_post params
    upvar #0 Httpd$sock data
    if {! [info exists data(mime,cf-ipcountry)]} {return 0}
    if {$data(mime,cf-ipcountry) ne "GB"} {return 0}
    if {[redis get "warn $user"] ne "(nil)"} {return 0}
    return 1
}

proc do_warn {sock suffix urec} {
    lassign $urec user can_post params
    if {$suffix eq "warned"} {
        # Skip lasts for one week
        redis set "warn $user" skip ex $::week_secs
        $sock redirect /
        return
    }
    html [heading $params]
    html {<h3>UK Access will be blocked from 16th March</h3>
You are seeing this page because you appear to be connecting from an IP address in the UK.
<p/>
On the 17th of March the UK's new Online Safety Act will start to be enforced.
I thank all those who answered my survey on this.
However I regret that I have concluded that it is not practical for this site to comply with the OSA.  So from 16th March I will block access from UK IP addresses, which puts it outside the scope of the act.
<p/>
Other web interfaces to Usenet are available, and may continue to allow UK users, see
<a href='https://en.wikipedia.org/wiki/Web-based_Usenet#Web-based_sites_and_popularity' target='_blank'>Wikipedia</a>.
<p/>
<form action='/warned' method='post'>
<input type=submit value='Continue' class='but' />
</form></body>}
    $sock htmlResponse $html
}
}

# Block UK users due to Online Safety Act
proc osa_block sock {
    $sock errorResponse 451 {
<h1>Blocked due to UK Online Safety Act</h1>
You appear to be connecting from an IP address in the United Kingdom.
Unfortunately this site is no longer available to UK users.
This is due to the requirements of the UK's Online Safety Act, which
are not practical for this site to comply with. If you feel this is
unjustified, I can only suggest that you write to your Member of Parliament.
This site remains in operation for non-UK users, as they are outside the scope of the Act.
<p/>
For more information see
<a href='https://www.ofcom.org.uk/online-safety/'>Ofcom's official site</a>,
and <a href='https://onlinesafetyact.co.uk/'>an unofficial guide</a>.
<p/>
Other web interfaces to Usenet are available, and may continue to allow UK users, see
<a href='https://en.wikipedia.org/wiki/Web-based_Usenet#Web-based_sites_and_popularity' target='_blank'>Wikipedia</a>.
                                                                     }
}

proc redirect_old_domain {sock suffix} {
    if {! [info exists ::old_site]} {return 0}
    if {[$sock getHeader host] ne $::old_site} {return 0}
    #after 2000
    if {[hack_attack $sock $suffix]} {return 1}
    #Httpd_Redirect https://$::this_site/$suffix $sock
    html "<body style='color: black; background-color: lightblue; font-family: Verdana'>"
    html "<h1>Site Moved</h1>\n"
    html "<h3>Newsgrouper is now at <a href='https://$::this_site'>$::this_site</a></h3>"
    html "<h3>Please update your bookmarks.</h3>\n</body>"
    $sock htmlResponse $html
    return 1
}

proc show_down sock {
    $sock errorResponse 503 {
<h1>Site down</h1>
Sorry, Newsgrouper is not able to operate right now.
<p/>
The server is down for database maintenance.
Newsgrouper will be back online as soon as possible.
                                                                     }
}

proc do_testy {urec sock} {
    #coroutine::util after 10000
    #error TESTY
    set res [get nh testy [incr ::testy]]
    return "TESTY $::testy res=$res"
}

proc daily_update {} {
    distcl::get $::redis nh daily [clock format now -format %d]
    after $::hour_ms daily_update
}
after $::hour_ms daily_update

proc userError {uri errInfo} {
    set date [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S} -gmt true]

    if {[string range $errInfo 0 17] eq {database is locked}} {
        set html {
<h2>Database Locked</h2>
Very sorry, we are experiencing a high volume of updates. :-( <br/>
Your request is important to us!<br/>
Please give it another try by <strong><em>reloading this page</em> [F5]</strong>.
}
        return [list 503 $html]
    }

    append html {
<h1>Server Error</h1>
500 apologies dear user! <br/>
We most humbly regret that we have been unable to process your valued request for
'} [enpre1 $uri] {' at } $date { GMT. <br/>
Please rest assured that those responsible have been alerted to this deplorable failure
and will strive most urgently to correct it.
}
    return [list 500 $html]
}

::wibbly::serve -handler reqHandler -port [dict get $cmd_opts port] -error2user userError

set sport [dict get $cmd_opts sport]
if {$sport} {
    package require tls
    tls::init -keyfile certs/skey.pem -certfile certs/server.pem -require 0
    ::wibbly::serve -handler reqHandler -port $sport -socketcmd ::tls::socket -error2user userError
}

puts RUNNING
vwait godot

