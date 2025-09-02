# Newsgrouper - a web interface to Usenet.

set ng_version 0.8.1

package require Tcl 9.0
package require mime

source scripts/retcl.tm
source scripts/nntp.tcl
#source scripts/reactcl.tcl
source scripts/distcl.tcl
source scripts/ng_config.tcl

# The back-end "newsgetter" process(es) provide "ng" and "na" services via distcl
catch { retcl create redis }
redis -async
interp alias {} get {} distcl::get redis
interp alias {} prefetch {} distcl::prefetch redis
interp alias {} html {} append html

Url_PrefixInstall / main

# a little debugging helper
proc printvars args {
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

# return html page heading
proc heading params {
    dict with params {}
    html "<!doctype html>
    <head><style type='text/css'>
    body {color:[validate_css_color $gen_fg]; background-color: [validate_css_color $gen_bg]; font-family: Verdana}
    .but {width: 8em;}
    .bbut {width: 10em;}
    .new {color:[validate_css_color $new_fg]; background-color: [validate_css_color $new_bg]}
    .rep {color:[validate_css_color $rep_fg]; background-color: [validate_css_color $rep_bg]}
    .quot {color: [validate_css_color $quo_fg]; background-color: [validate_css_color $quo_bg]}
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

# Main page - check login status, then dispatch as required.
proc main {sock suffix} {

    #tailcall show_down $sock
    if {[serve_static_file $sock $suffix]} return
    if {[redirect_old_domain $sock $suffix]} return
    if {[uk_user $sock]} {
        tailcall osa_block $sock
    }

    # If user is not logged in, show the login page
    set urec [get_user_record $sock]
    if {$urec eq {}} {
        if {[hack_attack $sock $suffix]} return
        tailcall show_login $sock $suffix
    }
    lassign $urec user can_post params

    if {[dict getdef $params banned 0]} {
        Httpd_Error $sock 403 BANNED
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
    {^tops$} {
        html [top_groups_read]
        html [top_groups_posted]
        html [big8_active_list] }
    {^post$} {
        html [do_post $urec $sock] }
    {^block$} {
        tailcall save_block $urec $sock }
    {^login$} {
        tailcall show_login $sock $suffix }
    {^logout$} {
        tailcall do_logout $urec $sock }
    {^preferences$} {
        html [edit_prefs $urec $sock] }
    {^save_prefs$} {
        html [save_prefs $urec $sock] }
    {^([[:alnum:]_\-\+]+\.[[:alnum:]_\.\-\+]+)(/.*)?$} {
        lassign $matches - group rest
        tailcall dispatch_group $urec $sock $group $rest }
    {^markup$} {
        html [toggle_pref $urec $sock mup] }
    {^reflow$} {
        html [toggle_pref $urec $sock flo] }
    {^rot13$} {
        html [toggle_pref $urec $sock r13] }
    {^allthr$} {
        html [toggle_pref $urec $sock apt] }
    {^reset_colours$} {
        html [reset_colours $urec $sock] }
    {^face/([[:graph:]]+)\.png$} {
        lassign $matches - addr
        tailcall get_face $sock $addr }
    {^msgid$} {
        html [do_msgid_search $urec $sock] }
    {^search$} {
        html [do_group_search $urec $sock] }
    {^<[[:graph:]]+@[[:graph:]]+>$} {
        html [do_msgid_art $urec $sock $suffix] }
    default {
        html "<br/>'$suffix' - THAT DOES NOT COMPUTE."
    } }

    set footing {</body>}
    Httpd_ReturnData $sock {text/html; charset=utf-8} \
        [encoding convertto [heading $params]$html$footing]
}

# Request specifies a group, process the rest of it.
proc dispatch_group {urec sock group rest} {
    lassign $urec user can_post params

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
    {^/upto/(\d+)$} {
        lassign $num_etc - num
        html [show_group $sock $urec $group $num] }
    {^/post$} {
        html [compose_new $urec $group] }
    {^/search/do$} {
        html [show_art_search $sock $urec $group] }
    {^/search/(\d+)$} {
        lassign $num_etc - num
        html [show_thread $urec $group $num $num 1] }
    {^/search/(\d+)/(\d+)$} {
        lassign $num_etc - start num
        html [show_thread $urec $group $start $num 1] }
    {^/rev$} {
        html [reverse_group $sock $urec $group] }
    {^/hide$} {
        tailcall hide_group $sock $urec $group }
    {^/charter$} {
        html [show_charter $group] }
    default {
        html "<br/>'$group$rest' - THAT DOES NOT COMPUTE."
    } }

    set footing {</body>}
    Httpd_ReturnData $sock {text/html; charset=utf-8} \
        [encoding convertto [heading $params]$html$footing]
}

# If the request is just for a static file, handle it here and return 1.
# If not return 0.
proc serve_static_file {sock suffix} {
    switch -glob -- $suffix {
	apple-touch-icon*.png {
            Httpd_ReturnFile $sock image/png htdocs/newsgrouper-icon.png
            return 1
        }
        *.asc -
        *.htm -
        favicon.ico -
        *.svg -
        *.png -
        *.gif {
            if {! [file readable htdocs/$suffix]} {return 0}
            Httpd_AddHeaders $sock Cache-Control max-age=$::week_secs
            Httpd_ReturnFile $sock [Mtype $suffix] htdocs/$suffix
            return 1
        }
    }
    return 0
}

proc hack_attack {sock suffix} {
    switch -glob -- $suffix {
        *.php -
        *.cgi -
        *.aspx {set mimetype text/html}
	.well-known/* {
            after 2000
            Httpd_Error $sock 404 "Return to sender, address unknown, no such number, no such zone."
            return 1
        }
        *.zip -
        .* -
        */.* -
        wp-* -
        */wp-* {set mimetype text/plain}
	default {return 0}
    }

    # Request is probing for vulnerabilities, serve them something appropriate.
    after 2000
    if {rand() < 0.2} {
        Httpd_Error $sock 404 "This is not the page you are looking for."
        return 1
    }
    if {rand() < 0.2} {
        Httpd_Redirect http://localhost/ $sock
        return 1
    }
    Httpd_AddHeaders $sock Content-Encoding gzip
    if {rand() < 0.2} {
        # Files hex[0-4] are gzipped containing various repetitions of
        # "Don't mention it. ++???++ Out of Cheese Error. Redo From Start."
        set file hex[expr {[string length $suffix] % 5}]
        Httpd_ReturnFile $sock $mimetype htdocs/$file
    } elseif {rand() < 0.2} {
        # generate and return a random amount (<=100kB) of random crap
        exec head -[expr {int(rand()*100000)}]c /dev/urandom > htdocs/random
        Httpd_ReturnFile $sock $mimetype htdocs/random
    } else {
        # return nothing, but log the request
        Log $sock Close
    }
    return 1
}

# Show the login page for guest or registered user.
proc show_login {sock suffix} {
    html {
<head><meta name='description' content='Read and post to Usenet Newsgroups with a simple web interface.'></head>
<body style='color: black; background-color: lightblue; font-family: Verdana'>
<span style='font-size: xx-large; color: purple'>Newsgrouper
<span style='color:green; margin-left: 20px'> &#x1F5E8;</span> &#x1F4AC; <span style='color:red'>&#x1F5EF;</span> &#x1F4AD;
</span>
<br/>
<span style='font-size:large'>
A web interface to Usenet discussion groups (no binaries)
</span>
<br/><br/>
<form action='/do/login' method='post'>
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
<input type=submit value="Continue as Guest" formaction='/do/guest' />
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
    html "<input type='hidden' name='suffix' value='$suffix' />\n"
    html {</form></body>}
    Httpd_ReturnData $sock text/html $html
}

package require sqlite3
sqlite3 userdb $::user_db -fullmutex 1
#userdb timeout 1000

package forget md5

Direct_Url /do

# Do login process for a registered user
proc /do/login {email pass suffix} {

    set fail_html {
<body style='background-color: pink'>
<h1>Newsgrouper Login Failed</h1>
Sorry, your email/password combination was not recognised.
<br/><br/> }
    append fail_html "<a href='/$suffix'>Try again.</a><br/><br/>"
    append fail_html {Alternatively <a href='/do/guest'>Continue as Guest</a>
- this allows reading but not posting.
</body>}

    if {$email eq "" || $pass eq ""} {return $fail_html}

    # Check the credentials are valid
    package require md5
    package require md5crypt
    set enc_email [md5crypt::md5crypt $email $::user_salt]
    set enc_pass [md5crypt::md5crypt $pass $::user_salt]

    set user [userdb eval {SELECT num FROM users WHERE email == $enc_email AND pass == $enc_pass}]
    if {$user eq {}} { return $fail_html }

    # BUGGY - DISABLED FOR NOW:
    #set user [upgrade_if_guest $user $enc_email $enc_pass]

    # Generate random cookie for user, write to their db record
    set salt [string range [clock clicks] end-7 end]
    set cookie [md5crypt::md5crypt [expr {rand()}] $salt]
    userdb eval {UPDATE users SET cookie = $cookie WHERE num = $user}
    tailcall finish_login $cookie 1 $suffix
}

# Check if already logged in as guest, if so upgrade user's guest db record.
proc upgrade_if_guest {user enc_email enc_pass} {
    lassign [Cookie_Get userhash] userhash
    #puts "upgrade_if_guest: user=$user userhash='$userhash'"
    if {$userhash in {{} -}} {return $user}

    # Find the user's previous db record
    lassign [userdb eval {SELECT num,email FROM users WHERE cookie == $userhash}] old_user old_email
    if {$old_email ne {}} {return $user}

    # Guest: move their credentials to their old db record to preserve their history
    #puts "Upgrading $old_user from $user"
    userdb transaction {
        userdb eval {DELETE FROM users WHERE num == $user}
        userdb eval {UPDATE users SET email = $enc_email, pass = $enc_pass WHERE num = $old_user}
    }
    return $old_user
}

# Do login process for a guest
proc /do/guest {suffix} {
    package require md5
    package require md5crypt
    # Generate cookie for user, write a temporary db record for them
    set salt [string range [clock clicks] end-7 end]
    set cookie [md5crypt::md5crypt [expr {rand()}] $salt]
    userdb eval {INSERT INTO users(cookie) VALUES($cookie)}
    tailcall finish_login $cookie 0 $suffix
}

# Do login confirmation page and complete the login process (guest or user)
proc finish_login {cookie registered suffix} {
    Cookie_Set -name userhash -value $cookie -path / -expires {next year} ;# TODO path needed?

    html {<body style='background-color: lightgreen'>
<h1>Newsgrouper Login</h1>
}
    set usertype [expr {$registered ? "Registered User" : "Guest"}]
    html "Logging in as a $usertype ..."
    html {
<br/><br/>
<em>This sets the only cookie this site uses.<br/>
It can be removed by clicking <strong>Log Out</strong>.</em>
<br/><br/>
}
    if {! $registered} {
        html {Note that as a guest, logging out will forget your history and preferences, \
            so when you return it will not be possible to show what postings are new \
            since your previous visit. }
    }
    html {As a registered user you can log out without losing your history and preferences.<br/><br/>}
    if {$suffix eq "login" || $suffix eq "logout"} {set suffix ""}
    html "<form action='/$suffix' method='post'>"
    html {
<input type=submit value='Continue' style='width: 20%' />
</form></body>}
    return $html
}

# Check if the user is logged in.
# If so, return their user number, whether they can post, and their
# preference settings.  If not, return empty string.
proc get_user_record sock {
    # Get the user's cookie
    lassign [Cookie_GetSock $sock userhash] userhash
    #puts "get_user_record: sock='$sock' userhash='$userhash'"
    if {$userhash in {{} -}} {return {}}

    # Find the user's db record
    userdb eval {SELECT num,email,params FROM users WHERE cookie == $userhash} {
        upvar #0 Httpd$sock data
        set data(mime,username) $num ;# for access log
        set can_post [expr {$email ne {}}]
        if {$can_post} {set data(mime,auth-user) *} ;# for access log
        set params [dict merge $::param_defaults $::colour_defaults $params]
        return [list $num $can_post $params]
    }
    return {}
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
    Httpd_SetCookie $sock [Cookie_Make -name userhash -value - -path / -expires now]

    html {<h1>Newsgrouper Logout</h1>
Logging Out...
<br/><br/>
<em>This clears the only cookie this site uses.</em>
<br/><br/>
<form action='/' method='post'>
<input type=submit value='Continue' style='width: 20%' />
</form>}
    Httpd_ReturnData $sock text/html $html
}

# Show the home page first section with general information
proc general_info urec {
    lassign $urec user can_post
    html {
A web interface to Usenet discussion groups (no binaries)
<span style='float: right'>
<form action='/none' method='post'>
}
    html "<input type=submit value='[expr {$can_post ? "Terms" : "Register"}]' formaction='/terms.htm'  class='but'/>\n"
    html "</form></span><br/>\n"
}

# Show the list of groups this user has previously read
proc show_groups_read {urec sock} {
    lassign $urec user can_post

    set prev_group {}
    set group_re {^https?://[^/]+/([[:alnum:]_\-\+]+\.[[:alnum:]_\.\-\+]+)}
    regexp $group_re [GetRefer $sock] - prev_group

    html {
<script type='text/javascript'>
function setup() {
	document.getElementById('sel').focus();
}
</script>
}
    set groups_read [groups_read $user]
    if {[llength $groups_read] == 0} {return ""}

    html {
<h3>Groups previously read</h3>
<table><thead>
<tr align='left'><th>Name</th><th>Description</th><th>New</th><th></th></tr>
</thead><tbody>
    }

    foreach {group desc new} $groups_read {
        if {$new} {
            html "<tr class='new'>"
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
        html "<td><a$id href=/$group>$group</a></td><td>[enpre $desc]</td><td>$new</td>"
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
            "<td>[enpre $desc]</td><td align='right'>$act</td></tr>\n"
    }

    html "</tbody>\n</table>\n<br/><br/>"

    if {[llength $groups] == 0} {set html {<h3>No Groups Found</h3>}}

    html [show_group_search]
    return $html
}

# Show the form to search for for a message by its id
proc show_msgid_search {} {
    html {
<h4>Find an article by message-id</h4>

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
    html "<h3>Article with message-id: [enpre $msgid]</h3>"
    if {! [regexp {<[[:graph:]]+@[[:graph:]]+>} $msgid]} {
        return "$html<h4>Invalid message-id.</h4>"
    }

    if [catch {get nh mid $msgid} art] {
        return "$html<h4>Article Not Found.</h4>"
    }
    lassign [parse_article $art] headers body
    return [show_article $urec $headers $body]
}

proc do_msgid_art {urec sock msgid} {
    set msgid [Url_Decode $msgid]
    if [catch {get nh mid $msgid} art] {
        return "$html<h4>Article Not Found.</h4>"
    }
    lassign [parse_article $art] headers body
    return [show_article $urec $headers $body]
}

proc other_info {} {
    html {<h3><a href='/tops'>Guide to the most active groups</a></h3>}
    html {<h3 style='background-color: lightgreen'>New Support Group for this site: 
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
<h3>Top twenty groups most read here</h3>
<table><thead>
<tr align='left'><th>Name</th><th>Description</th><th>Reads</th></tr>
</thead><tbody>
    }

    foreach group $group_list reads $read_list {
        set percent [expr {100 * $reads / $total_reads}]
	lassign [groupstat $group] desc

        html "<tr><td><a href=/$group>$group</a></td><td>[enpre $desc]</td><td align='right'>$percent%</td></tr>\n"
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
<h3>Top twenty groups with most posts globally</h3>
<table><thead>
<tr align='left'><th>Name</th><th>Description</th><th>Activity</th><th></th></tr>
</thead><tbody>
    }

    foreach {group posts} $group_posts {
        if {[catch {groupstat $group} desc_stat]} continue
	lassign $desc_stat desc

        html "<tr><td><a href=/$group>$group</a></td>" \
            "<td>[enpre $desc]</td><td align='right'>$posts</td></tr>\n"
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
        if {[catch {groupstat $group} desc_stat]} continue
	lassign $desc_stat desc

        html "<tr><td><a href=/$group>$group</a></td><td>[enpre $desc]</td></tr>\n"
    }

    html "</tbody>\n</table>\n"
    return $html
}

# Hack to avoid ::mime::field_decode failure on Chinese posts using charset GBK,
# see KBK's note at https://wiki.tcl-lang.org/page/Encoding+Translations+and+i18n
set ::mime::reversemap(gbk) gb2312

# Show the list of discussion threads for a group
proc show_group {sock urec group {upto 0}} {
    lassign $urec user can_post
    set prev_thread 0
    set prev_thread_re "[string map {. \\. + \\+} $group]/(\\d+)"
    regexp $prev_thread_re [GetRefer $sock] - prev_thread
    if {$prev_thread} {
        GetStash u$user.$group upto
    } else {
        PutStash u$user.$group upto
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
    if {[catch {lassign [groupstat $group] desc status}]} {
        return "<h3>Group '$group' not found.</h3>"
    }

    html "<span style='clear: right; float: right'>"
    html "<form action='/$group/post' method='post' style='display: inline'>"
    html "<input type=submit value='New Thread \U01F4DD' class='but' "
    if {! $can_post || $status eq "x"} {
        html {disabled='disabled' }
    }
    html "/> <input type=submit value='Search \U01F50D' class='but' "
    html "formaction='/$group/search/do' />\n"

    html {<input type=submit value='Group Charter' class='but' }
    html "formaction='/$group/charter' />\n"
    html "</form></span>\n"

    html "<h3><a href='/$group'>$group</a> '[enpre $desc]'</h3>\n"
    html "<base href='/$group/0' />\n"

    set threadinfo [cacheThreadinfo $urec $group $upto]
    dict with threadinfo {}

    set first [lindex $hdrs 0]
    set last [lindex $hdrs end-1]

    set old_last [prev_last $user $group $last]

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
<tr align='left'><th>Thread Subject</th><th>Originator</th>
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
        html "<td><a$id href='[html_attr_encode $start_num$tail]'>[enpre $sub]</a></td>"
	html "<td>[enpre $name]"
        if {[tsv::exists Faces $addr]} {
            html " <img src='/face/[Url_Encode $addr].png' width='20' align='top' style='float: right'>\n"
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
    if {$posts >= 300} {
        html {<input type=submit value='Older Posts' class='but' }
        html "formaction='/$group/upto/[expr {$first - 1}]' />\n"
    }

    html "</form>\n"

    return $html
}

# Get number of the last article when user previously read this group
proc prev_last {user group {last 0}} {
    # Article numbers after the ugrp old_last value will be considered new.
    # If the ugrp record does not already have a new_last value, set it.
    set ugrp [redis hget "ugrp $user" $group]
    lassign $ugrp old_last new_last
    if {$new_last eq {} && $last > 0} {
        redis hset "ugrp $user" $group [list $old_last $last]
    }
    return $old_last
}

# Reverse the display order of threads in a group
proc reverse_group {sock urec group} {
    lassign $urec user can_post params

    set reverse [dict get $params rev]
    set reverse [expr {$reverse==0 ? 1 : 0}]
    dict set params rev $reverse

    userdb eval {UPDATE users SET params = $params WHERE num = $user}
    clearThreadinfo $user
    Httpd_Redirect /$group $sock
}

# Show one discussion thread
proc show_thread {urec group start target insearch} {
    if [catch {get nh art $group $start} art] {
	set sub {}
    } else {
        lassign [parse_article $art] headers body
        set sub [dict getdef $headers Subject {}]
        catch {set sub [::mime::field_decode $sub]}
    }

    html "<a id='up' href='/$group' style='font-size: x-large'>$group</a>:"
    html "<span style='font-size: x-large'> [enpre $sub]</span>\n"

    html {<iframe style='position:fixed; left:0%; bottom:0%; height:80%; width:30%' }
    set thread_list [show_thread_list $urec $group $start $target $insearch]
    if {$thread_list eq {}} {set thread_list {"<br/>Thread not found.<br/>" 0 0 0 0}}
    set linx [lassign $thread_list list_html thread target]
    html "name='list' srcdoc=\"$list_html\"></iframe>\n"

    html {<iframe style='position:fixed; right:0%; bottom:0%; height:80%; width:69%' }
    lassign $urec user can_post params
    if [dict get $params apt] {
        set art_html [show_thread_arts $urec $group $thread $target $start]
    } else {
        set art_html [get_article $urec $group $target $start $linx]
    }
    html "name='art' srcdoc=\"[enpre2 $art_html]\"></iframe>\n"

    return $html
}

# Show the thread structure and posters for one discussion thread
proc show_thread_list {urec group start target insearch} {
    lassign $urec user can_post params

    # get the block of headers containing the thread start
    foreach upto [list 0 [expr {$start+250}]] {
        set threadinfo [cacheThreadinfo $urec $group $upto]
        dict with threadinfo {}
        if {[llength $hdrs] == 0} return
        set first [lindex $hdrs 0]
        if {$start >= $first+50} break
    }
    if {$threads eq ""} return

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
            if {$num > $target} continue
            if {[lsearch -stride 2 -integer $thr $target] != -1} {
                set found 1
                set thread $thr
                break
            }
        }
    }
    if {! $found} return

    # find target and previous articles
    set prev 0
    set pv 0
    foreach {num indent} $thread {
        set new [expr {$num > $old_last}]
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
    set indent 0
    set prev_ind $indent
    foreach {num indent} $thread {
        if {$indent < $prev_ind} {
            html {<tr style='height:6px'>} \
	        "<td colspan='[expr {30-1-$indent}]' class='rb'></td>" \
	        [string repeat {<td class='r'></td>} [expr {$indent+1}]] "</tr>\n"
	}

        set frag " id='a$num'"
        set clas rbl
        if {$num == $target} {
            append clas { sel}
        }
        if {$num > $old_last} {
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
        set frm [encoding convertfrom $frm]
        set parsed [lindex [::mime::parseaddress $frm] 0]
        set name [dict getdef $parsed friendly $frm]
        set addr [dict getdef $parsed address $frm]
        set dat [clock format $tim -format {%d %b %y}]
        html "<span style='float: right'>$dat</span>"
        html "<a href='$num'>$name</a>"
        if {[tsv::exists Faces $addr]} {
            html "<img src='/face/[Url_Encode $addr].png' width='20' hspace='5' align='top' style='float: right'>\n"
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
	set next_res [lindex $nums $pos+1]
	set prev_res [lindex $nums $pos-1]

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
        html "formaction='/$group/search/do' />"
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
    return [list $html $thread $target $nx $pv $nn]
}

# Lifted from Wibble:
# Encode for HTML <pre> by substituting angle brackets and ampersands.
proc enpre {str} {
    string map {< &lt; > &gt; & &amp; \" &quot; \r "" ' &#39;} $str
}
# Extra quoting step needed for srcdoc:
proc enpre2 {str} {
    string map {& &amp; \" &quot;} $str
}

# Security utility functions for XSS prevention
proc html_attr_encode {str} {
    # Encode for HTML attribute context to prevent XSS
    string map {< &lt; > &gt; & &amp; \" &quot; ' &#39; \r "" \n ""} $str
}

proc validate_url {url} {
    # Validate URL to prevent javascript: and data: scheme attacks
    set url [string trim $url]
    if {$url eq ""} {return ""}
    
    # Block dangerous schemes
    if {[regexp -nocase {^(javascript|data|vbscript):} $url]} {
        return ""
    }
    
    # Allow only http, https, ftp, and relative URLs
    if {![regexp {^(https?://|ftp://|/|[^:/?#]+)} $url]} {
        return ""
    }
    
    return [html_attr_encode $url]
}

proc validate_css_color {color} {
    # Validate CSS color values to prevent injection
    set color [string trim $color]
    if {$color eq ""} {return "#000000"}
    
    # Allow hex colors (#rgb, #rrggbb)
    if {[regexp {^#[0-9a-fA-F]{3}([0-9a-fA-F]{3})?$} $color]} {
        return $color
    }
    
    # Allow basic named colors
    set safe_colors {red green blue yellow orange purple pink black white gray grey}
    if {[string tolower $color] in $safe_colors} {
        return [string tolower $color]
    }
    
    # Default to black if invalid
    return "#000000"
}

proc show_thread_arts {urec group thread target start} {
    foreach {num indent} $thread {
        prefetch nh art $group $num
    }
    foreach {num indent} $thread {
        set clas art
        if {$num==$target} {append clas " target"}
        html "<span class='$clas' id='a$num'>"
        html [get_article $urec $group $num $start {}] <hr/>
        html "</span>"
    }
    return $html
}

# Generate an article display - this will be put in an iframe
proc get_article {urec group num thr linx} {
    if [catch {get nh art $group $num} art] {
        return "ARTICLE NOT FOUND: [enpre $art]"
    }
    lassign $urec user can_post params
    dict with params {}

    html "<head><style type='text/css'>
    body {color: $gen_fg; background-color: $gen_bg}
    .quot {color: $quo_fg; background-color: $quo_bg}
</style></head>"
    html {
<body onload='setup();'>
<script type='text/javascript'>
function keyDown(event) {
	//console.log('keyDown', event);
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
function setup() {
	//console.log('IN ART SETUP');
	window.focus();
	window.addEventListener('keydown', keyDown);

	let target = document.querySelector('.target');
	if (target) { target.scrollIntoView(); }

	window.addEventListener('scroll', scrolling);
}
</script>
    }

    redis zincrby groupreads 10 $group

    lassign [parse_article $art] headers body
    html [show_article $urec $headers $body]
    html [show_art_foot $urec $group $num $thr $linx $headers]
    html "\n</body>"
    return $html
}

# Format an article for display
proc show_article {urec headers body} {
    if {$headers eq {}} {
        html {FAILED TO PARSE ARTICLE:<br/><hr/>}
        html "<pre>\n[enpre $body]\n</pre>\n"
        return $html
    }
    lassign $urec user can_post params
    set markup [dict get $params mup]
    set reflow [dict get $params flo]
    set rot13 [dict get $params r13]

    set from [dict getdef $headers From {}]
    set parsed [lindex [::mime::parseaddress $from] 0]
    set addr [dict getdef $parsed address $from]
    if {$addr ne {}} {
        if {[dict exists $headers Face]} {
            # see spec at https://quimby.gnus.org/circus/face/
            set facedata [dict get $headers Face]
            tsv::set Faces $addr [binary decode base64 $facedata]
            html "<img src='/face/[Url_Encode $addr].png' alt='Face' style='float:right'>\n"
        } elseif {[dict exists $headers X-Face]} {
            set facedata [dict get $headers X-Face]
            tsv::set Faces $addr {}
	    if {[redis hset faces $addr $facedata]} {
                prefetch nu face $facedata
            }
            html "<img src='/face/[Url_Encode $addr].png' alt='X-Face' style='float:right'>\n"
        }
    }
    foreach hdr {From Newsgroups Subject Date} {
        set field($hdr) [dict getdef $headers $hdr {}]
        catch {set field($hdr) [::mime::field_decode $field($hdr)]}
        html "<em>${hdr}: [enpre $field($hdr)]</em><br/>\n"
    }
    html "<br/>\n"
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
        if {$markup} {
            html "[markup_art_line $line]\n"
        } else {
	    # make URLs clickable, encode <>
	    set url_re {https?://[[:alnum:]\-;,/?:@&=+$_.!~*'()#%]+}
	    set line [regsub -all $url_re $line "\x01&\x02"]
	    set line [enpre $line]
	    set line [regsub -all {\x01([[:graph:]]+)\x02} $line {<a href='\1' target='_blank'>\1</a>}]
            html "$line\n"
        }
        if {$reflow} {
            html "<br/>"
        }
    }
    if {! $reflow} {html "</pre>\n"}
    return $html
}

# Convert one article line to html
# (might I be overthinking this?)
proc markup_art_line line {
    # First tokenise line into a list of triples:
    # text before the token, token type, text of the token.
    # Token types are url, begin-emphasis, end-emphasis.
    set url_re {(https?://[[:alnum:]\-;,/?:@&=+$_.!~*'()#%]+)}
    set begin_emp_re {(?:(?:\A|\s)([*/_]+)[[:alnum:]])}
    set end_emp_re {(?:[[:alnum:]]([*/_]+)(?:\Z|\s))}
    set re "$url_re|$begin_emp_re|$end_emp_re"
    set indices [regexp -indices -all -inline -- $re $line]
    set start 0
    set ::tokens {}
    foreach {all url be ee} $indices {
        if {[lindex $url 0] > -1} {
            set tok u
	    lassign $url t0 t1
	} elseif {[lindex $be 0] > -1} {
            set tok b
	    lassign $be t0 t1
	} elseif {[lindex $ee 0] > -1} {
            set tok e
	    lassign $ee t0 t1
	}
        set pre_txt [string range $line $start $t0-1]
        set tok_txt [string range $line $t0 $t1]
        set start [expr {$t1 + 1}]
        lappend ::tokens $pre_txt $tok $tok_txt
    }
    lappend ::tokens [string range $line $start end] 0 {}

    return [lindex [markup_art_tokens] 1]
}

# Process a tokenised line (or part), generating html.
# Make URLs clickable, do emphasis with /*_
proc markup_art_tokens {{recursed 0}} {
    html {}
    while {[llength $::tokens]} {
        set ::tokens [lassign $::tokens pre_txt tok tok_txt]

        html [enpre $pre_txt]

        switch $tok {
            u { 
                set safe_url [validate_url $tok_txt]
                if {$safe_url ne ""} {
                    html "<a href='$safe_url' target='_blank'>[enpre $tok_txt]</a>"
                } else {
                    html "[enpre $tok_txt]"
                }
            }
            e { if {$recursed} {return [list $tok_txt $html]}
                html $tok_txt }
            b { lassign [markup_art_em_tokens $tok_txt] extra_end nested_html
		html $nested_html
		if {$recursed && $extra_end ne {}} {return [list $extra_end $html]}
                html $extra_end }
        }
    }
    return [list {} $html]
}

# Process an emphasised section, generating html.
# *stuff* => bold, /stuff/ => italic, _stuff_ => underlined.
proc markup_art_em_tokens unclosed {
    while {$unclosed ne {}} {
        lassign [markup_art_tokens 1] end nested_html
        html $nested_html
        set bl [split $unclosed {}]
        set el [split $end {}]
        set unclosed {}

	foreach {c out} {
            / {<em>$html</em>}
            * {<strong>$html</strong>}
            _ {<span style='text-decoration: underline'>$html</span>}
        } {
            if {$c in $bl} {
                if {$c in $el || $end eq {}} {
                    # Safe template substitution - replace $html with actual content
                    set safe_html [string map [list {$html} $html] $out]
                    set html $safe_html
                } else {
                    append unclosed $c
                }
            }
        }

        set unopened {}
	foreach c {/ * _} {
            if {$c ni $bl && $c in $el} {append unopened $c}
        }
        if {$unopened ne {}} {return [list $unopened $html]}
    }
    return [list {} $html]
}

# generate the buttons to show under an article
proc show_art_foot {urec group num thr linx headers} {
    lassign $urec user can_post params
    set from [dict getdef $headers From {}]
    set parsed [lindex [::mime::parseaddress $from] 0]
    set name [dict getdef $parsed friendly {}]
    set addr [dict getdef $parsed address {}]
    set markup [dict get $params mup]
    set reflow [dict get $params flo]
    set rot13 [dict get $params r13]
    set allthr [dict get $params apt]
    lassign [groupstat $group] desc status
    if {[dict exists $headers Message-ID]} {
        set msgid [dict get $headers Message-ID]
    } else {
        set msgid [dict getdef $headers Message-Id {}]
    }


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
        html "formaction='/do/block' formtarget='_self' />"
    } else {
        html "disabled='disabled' />"
    }
    html "<input type='hidden' name='name' value='[enpre $name]' />"
    html "<input type='hidden' name='address' value='$addr' />"
    html "<input type='hidden' name='group' value='$group' />"
    html "<input type='hidden' name='num' value='$num' />"
    html "<input type='hidden' name='thr' value='$thr' />"

    html "\n<input id='vs' type=submit value='View Source \U01F1FB' formaction='/$group/$num/raw' formtarget='viewsource' class='bbut' />"

    html "\n<input id='mu' type=submit value='[tick $markup] Markup \U01F1F2' formaction='/markup' class='bbut' />"
    html "\n<input id='rf' type=submit value='[tick $reflow] Wrap \U01F1FC' formaction='/reflow' />"
    html "\n<input id='ro' type=submit value='[tick $rot13] Rot13 \U01F1F7' formaction='/rot13' />"
    html "\n<input id='ap' type=submit value='[tick $allthr] All posts \U01F1E6' formaction='/allthr' />"
    html "\n<a href='/$msgid' target='_blank'>Permalink</a>"

    html </form>
    return $html
}

proc tick setting {
    expr {$setting ? "\U2705" : "\U274E"}
}

# Show a single article in raw unprocessed form
proc show_article_raw {sock group num} {
    set art [get nh art $group $num]
    html "<pre>\n[enpre $art]\n</pre>\n"
    Httpd_ReturnData $sock {text/html; charset=utf-8} [encoding convertto $html]
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

    Httpd_Redirect [GetRefer $sock] $sock
}


# Show block confirm/cancel page
proc /do/block {name address group num} {
    html "<h3>Block User '[enpre $name]'</h3>"
    html "Proceeding will hide all messages from address '$address'"
    html {<br/><br/>
    <form action='/block' method='post'>}
    html {<input type=submit value='Confirm Block' class='bbut' />}
    html "<input type=submit value='Cancel' formaction='/$group/$num' formtarget='_top' class='bbut' />"
    html "<input type='hidden' name='address' value='$address' />"
    html </form>
    return $html
}

# Block unwanted address
proc save_block {urec sock} {
    lassign $urec user can_post params
    upvar #0 Httpd$sock data
    set query [Url_DecodeQuery $data(query)]
    if {! [dict exists $query address]} return
    set address [string trim [dict get $query address]]

    dict lappend params block $address
    userdb eval {UPDATE users SET params = $params WHERE num = $user}

    html "<h3>Address '$address' Now Blocked</h3>\n"
    html {The list of blocked addresses can be seen and edited by clicking Preferences.<br/>}

    Httpd_ReturnData $sock {text/html; charset=utf-8} [encoding convertto $html]
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
    lassign $urec user can_post params
    html "<h3>Preferences for [expr {$can_post ? "User " : "Guest "}] $user</h3>\n"

    dict with params {}
    set blocks [join $block \n]

    # ugrp stores User GRouP info
    set ugrps [redis hgetall "ugrp $user"]
    set groups {}
    foreach {group ugrp} $ugrps {
        lassign $ugrp last
        append groups "$group $last\n"
    }

    html {
<form action='/save_prefs' method='post'>}

    html [pref_label {Groups To Show:<br/>
<em><span style='font-size: small'>(Each line lists one group, optionally
followed by the highest article number when you last read this group.)
</span></em>}]
    html "<textarea name='groups' rows='10' cols='50'>$groups</textarea><br/>"

    html [pref_label {Newest Threads:}]
    html \
"<input type='radio' name='rev' value='0' [expr {$rev ? "" : "checked='checked'"}] />Last " \
"<input type='radio' name='rev' value='1' [expr {$rev ? "checked='checked'" : ""}] />First "

    html [pref_label {<br/>Blocked Posters:
<br/><em><span style='font-size: small'>(Hide posts from these addresses,
listed one per line.)</span></em>}]
    html {<br/>
<textarea name='blocks' rows='10' cols='50'>} \
    "$blocks</textarea><br/>"

    html [pref_label {Markup in Posts:}]
    html \
"<input type='radio' name='mup' value='0' [expr {$mup ? "" : "checked='checked'"}] />Off " \
"<input type='radio' name='mup' value='1' [expr {$mup ? "checked='checked'" : ""}] />On" \
{ <em><span style='font-size: small'>
(*words* => bold, /words/ => italic, _words_ => underlined)</span></em><br/>}

    html [pref_label {Wrap Long Lines:}]
    html \
"<input type='radio' name='flo' value='0' [expr {$flo ? "" : "checked='checked'"}] />Off " \
"<input type='radio' name='flo' value='1' [expr {$flo ? "checked='checked'" : ""}] />On" \
{ <em><span style='font-size: small'>
(use proportional font and wrap long lines)</span></em><br/>}

    html [pref_label {All Thread Posts:}]
    html \
"<input type='radio' name='apt' value='0' [expr {$apt ? "" : "checked='checked'"}] />Off " \
"<input type='radio' name='apt' value='1' [expr {$apt ? "checked='checked'" : ""}] />On" \
{ <em><span style='font-size: small'>
(show all posts in a thread instead of one at a time)</span></em><br/><br/>}

    html [pref_label {Posting Name:}]
    html "<input type='text' name='from' value='$from' size='50' maxlength='50'/><br/>"

    html [pref_label {<br/>Signature:}]
    html "<textarea name='sig' rows='4' cols='70'>$sig</textarea><br/>"

    html [pref_label {Extra Headers:<br/><em><span style='font-size: small'>
(Leave this empty unless you really know what you're doing)</span></em>}]
    html "<textarea name='xhdrs' rows='4' cols='70'>$xhdrs</textarea><br/><br/>"

    html [pref_label {Colours:}]
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
</form>}
    return $html
}

proc pref_label text {
    return "\n<span style='clear: left; width: 20%; float: left'>$text</span>\n"
}

proc colour_input {text var} {
    upvar $var val
    return "<span>$text</span><input type='color' name='$var' value='$val' />"
}

# Save user's preferences
proc save_prefs {urec sock} {
    lassign $urec user can_post
    upvar #0 Httpd$sock data
    set query [Url_DecodeQuery $data(query)]
    foreach field {blocks groups} {
        if {! [dict exists $query $field]} {
	    return "<br/><em>Save failed: '$field' missing.</em>"
	}
        set $field [string trim [dict get $query $field]]
        dict unset query $field
    }
    set blocklist {}
    foreach block [split $blocks \n] {
        lappend blocklist [string trim $block]
    }
    dict set query block $blocklist
    set params [dict get $query]
    userdb eval {UPDATE users SET params = $params WHERE num = $user}

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
    Httpd_Redirect / $sock
}

# Reset user's colour preferences to the defaults
proc reset_colours {urec sock} {
    lassign $urec user can_post params
    set params [dict merge $params $::colour_defaults]
    userdb eval {UPDATE users SET params = $params WHERE num = $user}

    Httpd_Redirect / $sock
}

# remove group from the user's home page
proc hide_group {sock urec group} {
    lassign $urec user can_post
    redis hdel "ugrp $user" $group
    Httpd_Redirect / $sock
}

# Implement a simple cache, shared between threads
package require Thread

# Calculate and cache article thread info which depends on user, group and upto
proc cacheThreadinfo {urec group upto} {
    if {[checkThreadinfoBypass $group]} {
        tailcall calcThreadinfo $urec $group $upto
    }
    lassign $urec user can_post params
    set arglist [list $user $group $upto]
    set now [clock seconds]
    set timeout 300
    if {[tsv::get Threadinfo $arglist value]} {
        lassign $value time data
        if {$time + $timeout > $now} {
            return $data
        }
        tsv::unset Threadinfo $arglist
    }
    set data [calcThreadinfo $urec $group $upto]
    tsv::set Threadinfo $arglist [list $now $data]
    return $data
}

# Calculate article thread info which depends on user, group and upto
proc calcThreadinfo {urec group upto} {
    lassign $urec user can_post params
    set blocklist [dict get $params block]
    set reverse [dict get $params rev]

    set hdrs [get nh hdrs $group $upto]
    #set hdrs [lsort -stride 2 -integer $hdrs]

    lassign [get_threads $hdrs $blocklist $user] threads blocked reply_nums
    set threads [lsort -stride 2 -integer $threads]

    lassign [redis hget "ugrp $user" $group] old_last

    set threadcounts {}
    foreach {start_num thread} $threads {
        set thread_posts [expr {[llength $thread] / 2}]
        set new_posts 0
        set replies 0
        foreach {num indent} $thread {
            if {$num > $old_last} {
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
    foreach key [tsv::array names Threadinfo] {
        if {[lindex $key 0] eq $user} {
            tsv::unset Threadinfo $key
        }
    }
}

proc bypassThreadinfo {group timeout} {
    set expiry [expr {[clock seconds] + $timeout}]
    tsv::set ThreadinfoBypass $group $expiry
}

proc checkThreadinfoBypass group {
    set now [clock seconds]
    if {[tsv::get ThreadinfoBypass $group expiry]} {
        if {$now < $expiry} {return 1}
        tsv::unset ThreadinfoBypass $group
    }
    return 0
}

# short-term storage of context-specific data
proc PutStash {context args} {
    foreach var $args {
        upvar $var st[incr n]
        lappend vars $var [set st$n]
    }
    tsv::set Stash $context [list [clock seconds] $vars]
}

proc GetStash {context args} {
    if {[llength $args] == 0} return
    if {! [tsv::get Stash $context value]} {return $args}
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
set cacheMaxAge 3600 ;# 1 hour in seconds
proc cacheGC {} {
    set agelimit [expr {[clock seconds] - $::cacheMaxAge}]

    # remove old Stash entries
    foreach {key value} [tsv::array get Stash] {
        if {[lindex $value 0] < $agelimit} {
            tsv::unset Stash $key
        }
    }
    # remove old Threadinfo entries
    foreach {key value} [tsv::array get Threadinfo] {
        if {[lindex $value 0] < $agelimit} {
            tsv::unset Threadinfo $key
        }
    }
}

set cacheGCinterval [expr {$cacheMaxAge * 1000}]
after $cacheGCinterval doCacheGC
proc doCacheGC {} {
    #puts "Running cacheGC"
    cacheGC
    after $::cacheGCinterval doCacheGC
}

# Load group statuses and descriptions into thread-shared value.
foreach {group stat desc} [get nh groupstats] {
    catch {set desc [encoding convertfrom utf-8 $desc]}
    tsv::set Groupstats $group [list $desc $stat]
    incr numgroups
}

proc groupstat group {
    tsv::get Groupstats $group
}

# Look for specified variables in the request's data.
# If found, set them in the caller's scope.
# Return a list of any not found.
proc GetQuery {sock args} {
    upvar #0 Httpd$sock data
    set query [Url_DecodeQuery $data(query)]
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

proc GetRefer sock {
    upvar #0 Httpd$sock data
    if {[info exists data(mime,referer)]} {
        return $data(mime,referer)
    }
    return /
}

# Run an article search and show the results
proc show_art_search {sock urec group} {
    lassign $urec user can_post
    set subj {}
    set from {}
    set date {}
    set nexttim {}

    # Are we returning from viewing a search result?
    set prev_result 0
    set prev_result_re "[string map {. \\. + \\+} $group]/search/(\\d+)"
    regexp $prev_result_re [GetRefer $sock] - prev_result
    if {$prev_result} {GetStash s$user.$group subj from date}

    if {[llength [GetQuery $sock clear]]} {
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

    lassign [get nh find $group $subj $from $tim] more_tim hdrs

    html {
<script type='text/javascript'>
function setup() {
	document.getElementById('sel').focus();
}
</script>
}
    html {
<form action='do' method='post'>
<span style='float: right'>
<input type='submit' value='Search' name='search' class='but' />
<input type='submit' value='Clear' name='clear' class='but' />
</span>
    }
    html "<input type='hidden' name='nexttim' value='$more_tim' />\n"
    html "<h3>Search <a href='/$group'>$group</a> articles for</h3>"
    html {
<table><thead>
<tr align='left'><th>Subject including</th><th>Author including</th><th>Date up to</th></tr>
<tr align='left'>
    }
    html "<th><input type='text' name='subj' size='50' value='$subj'/></th>"
    html "<th><input type='text' name='from' size='30' value='$from'/></th>"
    html "<th><input type='date' name='date' min='1987-01-01' value='$date'/></th>"
    html {
</tr>
</thead><tbody>
    }

    lassign [redis hget "ugrp $user" $group] old_last
    set nums {}
    foreach {num detail} $hdrs {
        lappend nums $num
        lassign $detail prev sub frm tim msgid
        set sub [encoding convertfrom $sub]
        set frm [encoding convertfrom $frm]
        set dat [clock format $tim -format {%d %b %y}]
 
        if {$num > $old_last} {
            html "<tr class='new'>"
        } else {
            html "<tr>"
        }
        set id {}
        if {$num eq $prev_result} {
            set id " id='sel'"
        }
        html "<td><a$id href='[html_attr_encode $num]'>[enpre $sub]</a></td>"
	html "<td>[enpre $frm]</td><td>$dat</td></tr>\n"
    }
    html "<tr><td/><td/><td>"
    html "<input type='submit' value='Earlier Dates' name='more' class='but' "
    if {! $more_tim} {html "disabled='disabled' "}
    html "/></td></tr>\n"
    html "</tbody></table>\n"
    html "</form>\n"

    if {[llength $hdrs] == 0} {
        html "<h3>No Matches Found</h3>"
    }
    if {! $prev_result} {PutStash s$user.$group subj from date nums}

    return $html
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
            set charter [get nu charter $group]
            if {$charter eq {}} {set charter "Unable to retrieve charter."}
            return [html "<pre>[enpre $charter]</pre>"]
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
    lassign $args groups subject refs body msg
    if {[string trim $groups] eq {}} {set groups $group}
    set grouplist [split $groups ,]

    if {[spam_check $user $body $grouplist]} {
        return "<br/><em>Sorry, you have exceeded the maximum number\
            or volume of posts allowed in one day.</em>"
    }
    if {[catch {moderated $grouplist} moderated]} {
        append msg "<br/>$moderated"
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
    set sig [dict get $params sig]
    if {$sig ne {} && [string first "\n-- \r" $body] == -1} {
        append body "\n\n-- \n$sig"
    }
    html "<h3>Create New Article</h3>\n"
    if {$msg ne {}} {html "<span style='color:red'><em>$msg</em></span>\n"}
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
    html [form_field Subject subject $subject] \
"<textarea name='body' rows='20' cols='80' wrap='off' style='font-size: large'>$body</textarea>" \
{<br/>
<input type=submit value='Post' style='width: 10em' />} \
    "<input type=submit value='Quit' style='width: 10em' formaction='/$group'/>" \
    "<input type='hidden' name='group' value='$group' />\n" \
    "<input type='hidden' name='refs' value='$refs' /></form>\n"

    return $html
}

proc form_field {label name value} {
    html "<span style='font-size: large; width: 10em; float: left'>${label}:</span>"
    html "<input type='text' name='$name' size='70' value='[enpre $value]' />"
    html "<br clear='left'/>\n"
}

# Start a post in reply to an existing article
proc compose_reply {urec group num} {
    if [catch {get nh art $group $num} art] {
        return {Post not found.}
    }
    lassign [parse_article $art] headers old_body
    if {$headers eq {}} {
        return {Post not found.}
    }
    if {[dict exists $headers Followup-To]} {
        set groups [dict get $headers Followup-To]
    } else {
        set groups [dict get $headers Newsgroups]
    }
    set old_sub [dict get $headers Subject]
    catch {set old_sub [::mime::field_decode $old_sub]}
    if {[string match -nocase {Re: *} $old_sub]} {
        set subject $old_sub
    } else {
        set subject "Re: $old_sub"
    }
    if {[dict exists $headers Message-ID]} {
        set msgid [dict get $headers Message-ID]
    } else {
        set msgid [dict get $headers Message-Id]
    }
    if {[dict exists $headers References]} {
        set refs "[dict get $headers References] $msgid"
    } else {
        set refs $msgid
    }
    set body "[dict get $headers From] posted:\n\n"
    foreach line $old_body {
        if {$line eq "-- "} break
        append body "> $line\n"
    }
    return [compose_new $urec $group $groups $subject $refs $body]
}

# Send a new post to the news server
proc do_post {urec sock} {
    lassign $urec user can_post params
    if {! $can_post} {
        return {<br/><span style='color:red'><em>
            Sorry, you need to register and log in to post.</em></span>}
    }

    upvar #0 Httpd$sock data
    set query [Url_DecodeQuery $data(query)]
    foreach field {from subject group groups refs body} {
        if {! [dict exists $query $field]} {
	    return "<br/><em>Post failed: '$field' missing.</em>"
	}
        set $field [string trim [dict get $query $field]]
    }
    foreach field {from subject groups body} {
        if {[set $field] eq ""} {
            set msg "[string totitle $field] cannot be empty"
            return [compose_new $urec $group $groups $subject $refs $body $msg]
        }
    }
    set grouplist [split $groups ,]
    if {[catch {moderated $grouplist} moderated]} {
        return [compose_new $urec $group {} $subject $refs $body $moderated]
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
    regsub -all {<.*>} $from {} from
    set from [field_encode $from]
    append txt "From: $from <user$user@$::this_site.invalid>\n"
    append txt "Newsgroups: $groups\n"
    append txt "Subject: [field_encode $subject]\n"
    if {$refs ne {}} {
        append txt "References: $refs\n"
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

    set xhdrs [dict get $params xhdrs]
    append txt [string trim [string map [list "\r\n" "\n"] $xhdrs]] "\n"
    catch {set body [encoding convertfrom $body]}
    append txt "\n" $body
    html "<h3>Group <a href=/$group>$group</a></h3>\n"
    if $uucp {
        html "[send_uucp $txt]\n"
    } else {
        html "[send_nntp $txt]\n"
    }
    bypassThreadinfo $group 300 ;# disable caching for next 5 min
    if {$from ne [dict get $params from]} {
        dict set params from $from
        userdb eval {UPDATE users SET params = $params WHERE num = $user}
    }
    return $html
}

# Encode a header field with the shorter of base64 or quoted-printable
proc field_encode text {
    if {[::mime::encodingasciiP $text]} {return $text}
    if {[catch {
        set encB [::mime::word_encode utf-8 base64 $text]
        set encQ [::mime::word_encode utf-8 quoted-printable $text]
    }]} {return $text}

    if {[string length $encB] < [string length $encQ]} {
        return $encB
    } else {
        return $encQ
    }
}

#### Data Access Stuff ####

# Return the list of group names and descriptions which match a pattern.
# pattern is the glob-style pattern to look for;
# match_name is whether to match against the group name;
# match_desc is whether to match against the group description.
proc groups_matching {pattern match_name match_desc} {
    set matched {}
    foreach {group status} [tsv::array get Groupstats] {
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

# Return the list of groups the user has previously read.
# For each group returns name, description & number of new
# posts since last read by this user.
# The ugrp record for a user is a map from each group read to
# the last article present when this user last read the group.
proc groups_read user {
    set result {}
    set ugrps [redis hgetall "ugrp $user"]

    # kick off fetching the group counts so this can be done in parallel
    foreach {group ugrp} $ugrps {
        prefetch nh group $group
    }

    foreach {group ugrp} $ugrps {
        # The ugrp record may also contain a new value
        # which should now replace the old one:
        lassign $ugrp old_last new_last
        if {$new_last ne {}} {
            lappend ugrp_updates $group $new_last
            set old_last $new_last
        }
        catch { # if group not found, skip it
            lassign [groupstat $group] desc status
            lassign [get nh group $group] est first last
            set new [expr {max(0, $last - $old_last)}]
            lappend result $group $desc $new
        }
    }
    if {[info exists ugrp_updates]} {
        redis hset "ugrp $user" {*}$ugrp_updates
    }
    return $result
}

# Use the 'prev' links in the headers list to build the thread structure.
# While doing this skip all posters the user has blocked.
# Returns a list alternating:
#   - start of thread (article number)
#   - list of articles in the thread and their indentation level.
# Also returns total number of blocked posts,
# and list of replies to current user's posts.
proc get_threads {hdrs blocklist user} {
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
        lassign $detail prev sub frm tim id
        set sub [encoding convertfrom $sub]
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
        if {$address in $blocklist} {
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
        dict set ::followups $num {}
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
        do_thread $num 0
        set start [lindex $::post_indent 0]
        lappend threads $start $::post_indent
    }
    return [list $threads $blocks $reply_nums]
}

# recursively build the structure of one thread into ::post_indent
proc do_thread {num indent} {
    if {$num > 0} {
        lappend ::post_indent $num $indent
    }
    set fups [dict get $::followups $num]
    incr indent [llength $fups]
    foreach f $fups {
        do_thread $f [incr indent -1]
    }
}

# Parse an article from the news server, return a dict of the headers
# and a list of body lines.
proc parse_article {art} {

    # kludge to fix unrecognised encoding
    regsub -all -line {^Content-Transfer-Encoding:\s+8-bit\s*$} $art \
        {Content-Transfer-Encoding: 8bit} art

    if [catch {::mime::initialize -string $art} mt] {
        #puts "::mime::initialize FAILED: '$mt'"
        tailcall parse_article_a $art
        #return {}
    }
    if [catch {::mime::getheader $mt} headers] {
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

    if [catch {::mime::getbody $bt -decode} body] {
        if [catch {::mime::getbody $bt} body2] {
            set body "ERROR \"$body2\" in ::mime::getbody"
        } else {
            set body "ERROR \"$body\" while decoding:\n\n$body2"
        }
    }
    ::mime::finalize $mt
    return [list $headers [split $body \n]]
}

# Attempt to parse an article in the ancient A format
proc parse_article_a art {
    if {[string index $art 0] ne "A"} {return [list {} $art]}
    set body [lassign [split $art \n] id grps from date sub]
    if {[string first $id :] != -1} {return [list {} $art]}
    set headers [dict create From $from Newsgroups $grps Subject $sub Date $date]
    return [list $headers $body]
}

# Get the image for an X-Face header from the nu (newsutility) service
proc get_face {sock addr} {
    Httpd_AddHeaders $sock Cache-Control max-age=300
    set addr [Url_Decode $addr]
    if {[tsv::get Faces $addr png] && $png ne {}} {
        Httpd_ReturnData $sock image/png $png
        return
    }
    set facedata [redis hget faces $addr]
    if {$facedata eq "(nil)"} {
        Httpd_Error $sock 404 "Failed to find face data."
        return
    }
    if {[catch {get nu face $facedata} png]} {
        Httpd_Error $sock 404 "Failed to decode face data '$png'."
        return
    }
    tsv::set Faces $addr $png
    Httpd_ReturnData $sock image/png $png
}
tsv::set Faces {} {}

# Send a new article to the news server using NNTP.
# txt is the whole article.
proc send_nntp txt {
    set txt [encoding convertto $txt]
    if [catch {get ng post $txt} result] {
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
set day_secs [expr {60*60*24}];# 24 hours in seconds
set week_secs [expr {$day_secs*7}];# 7 days in seconds

set morph_limit 0
#set morph_limit 5
set morph_timeout $day_secs
set morph_reserve [expr {60*15}] ;# 15 minutes in seconds

# Are any of these groups moderated?
proc moderated groups {
    foreach group $groups {
        if {[catch {groupstat $group} desc_stat]} {error "Invalid Group: '$group'"}
        set status [lindex $desc_stat 1]
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
    # check if they are over one of the limits
    if {$count >= $::spam_max_count || $volume > $::spam_max_volume} {return 1}

    # cross-posts count as multiple posts
    set group_count [llength $grouplist]
    set new_volume [expr {[string length $body] * $group_count}]
    if {$new_volume > $::spam_max_volume} {return 1}

    # if posting, update their totals
    if {$update} {
        set user_spam_record [list [incr count $group_count] [incr volume $new_volume]]
        redis set $usp $user_spam_record ex $::day_secs
    }
    return 0
}
set spam_max_count 50
set spam_max_volume 100000

#### Site Status Stuff ####

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
        Httpd_Redirect / $sock
        return
    }
    set comment {}
    set missing [GetQuery $sock impact comment]
    if {$suffix eq "survey" && ! [llength $missing]} {
        set data [list $can_post $impact $comment]
        redis set "survey $user" $data
        Httpd_Redirect / $sock
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
    Httpd_ReturnData $sock {text/html; charset=utf-8} [encoding convertto $html]
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
        Httpd_Redirect / $sock
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
    Httpd_ReturnData $sock {text/html; charset=utf-8} [encoding convertto $html]
}

# Block UK users due to Online Safety Act
proc uk_user sock {
    upvar #0 Httpd$sock data
    if {! [info exists data(mime,cf-ipcountry)]} {return 0}
    if {$data(mime,cf-ipcountry) ne "GB"} {return 0}
    return 1
}

proc osa_block sock {
    Httpd_Error $sock 451 {
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
    upvar #0 Httpd$sock data
    if {! [info exists data(mime,host)]} {return 0}
    if {$data(mime,host) ne $::old_site} {return 0}
    #after 2000
    if {[hack_attack $sock $suffix]} {return 1}
    #Httpd_Redirect https://$::this_site/$suffix $sock
    html "<body style='color: black; background-color: lightblue; font-family: Verdana'>"
    html "<h1>Site Moved</h1>\n"
    html "<h3>Newsgrouper is now at <a href='https://$::this_site'>$::this_site</a></h3>"
    html "<h3>Please update your bookmarks.</h3>\n</body>"
    Httpd_ReturnData $sock {text/html; charset=utf-8} [encoding convertto $html]
    return 1
}

proc show_down sock {
    Httpd_Error $sock 503 {
<h1>Site down</h1>
Sorry, Newsgrouper is not able to operate right now.
<p/>
There appears to be a fault with the upstream server news.eternal-september.org.
Newsgrouper will be back online as soon as possible.
                                                                     }
}
