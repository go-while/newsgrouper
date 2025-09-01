# Various tweaks to the server

# Add missing mime types
set ::MimeType(.png) image/png
set ::MimeType(.ico) image/ico

# Hack to get the user's country as reported by Cloudflare into the httpd log.

Log_Configure -lognames 1

proc Httpd_Peername sock {
    upvar #0 Httpd$sock data
    if [info exists data(mime,cf-ipcountry)] {return $data(mime,cf-ipcountry)}
    return $data(ipaddr)
}

# Return 404 status when file not found.

package require httpd

rename Doc_NotFound Doc_NotFound.orig

proc Doc_NotFound sock {
    upvar #0 Httpd$sock data
    Httpd_Error $sock 404 "'$data(suffix)' not found."
}

# On internal error, give the user a polite response, log the details.
proc Doc_Error {sock errorInfo} {
    upvar #0 Httpd$sock data
    set date [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S} -gmt true]

    file mkdir log
    set err_log [open log/errors a]
    puts $err_log "$date $data(suffix)\n$errorInfo\n"
    close $err_log

    append html {
<h1>Server Error</h1>
500 apologies dear user! <br/>
We most humbly regret that we have been unable to process your valued request for
'} $data(suffix) {' at } $date { GMT. <br/>
Please rest assured that those responsible have been alerted to this deplorable failure
and will strive most urgently to correct it.
}
    Httpd_ReturnData $sock text/html $html 500
}

