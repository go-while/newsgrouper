# Wibbly #

wibbly - a basic web server, receives and responds to HTTP 1.1 requests

**package require wibbly**

## HTTP Server

**::wibbly::serve** *?option value ...?*  

Opens a server socket which listens for HTTP requests and responds to them.  This command will return immediately.  To actually wait for requests you need to enter the event loop, e.g. by calling **vwait**.  Other events can then be processed in parallel, such as responding to a Tk GUI.
**::wibbly::serve** will process each http connection in a separate *coroutine*.  To avoid blocking the whole server, handler code should use the coroutine-aware commands in **::coroutine::util** for any operations which involve waiting.
The following options can be specified:

**-port** *port*  
    The IP port to listen on.  Defaults to 8080.

**-socketcmd** *command*  
    The command to use to open the server socket.  The default is **socket** but **::tls::socket** can be specified to support https.

**-handler** *command*  
The command specified will be called to process each http request received.  It will be called with a single argument, a *web object* of the class **wobbly**, documented below.  The default handler just returns a web page describing the request received.

**-accesslog** *filename*  
This specifies the name of a file where each request received will be logged.  The name may contain variables and commands, which will be substituted by calling **subst**. The default is `/tmp/wibbly.$port.[clock format now -format {%y.%m.%d}].log` which will start a new log file for each day.  Setting the name to an empty string will disable request logging.

**-errorlog** *filename*  
This specifies the name of a file where any uncaught errors in request processing will be logged.  This name will also be substituted by **subst**.  The default is `/tmp/wibbly.$port.errors`.

**-error2user** *command*  
This specifies a command which will be called for any uncaught errors in request processing. The command will be called with two arguments, the URI requested and the Tcl errorInfo.  The command should return a list of two values, the HTTP error code and the html for any message to be returned to the user.  The default returns error code 500 (internal error) and the message `Sorry, the server failed to process your request for '$uri' at $date GMT.`

## HTML Utilities

**::wibbly::template** *body*  
Expand a template.  Lines in the template body starting with % are treated
as code and executed.  All other lines become part of the result after
variable and command substitution.

**::wibbly::enhtml** *string*  
Encode string for HTML by substituting angle brackets, ampersands, space sequences,
and line breaks.

**::wibbly::enattr** *string*  
Encode string for HTML tag attribute by substituting angle brackets, ampersands,
space sequences, and single and double quotes.

**::wibbly::enpre** *string*  
Encode string for HTML \<pre\> by substituting angle brackets and ampersands.

**::wibbly::enhex** *string ?pattern?*  
Encode string by substituting most non-alphanumerics with hexadecimal codes.

**::wibbly::dehex** *string*  
Decode hexadecimal encoding of string.
 

## Web Objects

For each request received, the user's handler is called with a *web object* which encapsulates the application's interface to the web server.  Web Objects (wobs) belong to the class **wobbly** and support the following methods:

**getPath**  
Returns the path which was requested.

**getHeader** *name*  
Returns the header with the specified name from the request, or an empty string if it does not exist.

**getCookie** *name*  
Returns the value of the *cookie* with the specified name from the request, or an empty string if it does not exist.

**getFormdata**  
Returns a name/value dict of all the form data sent in the request,
whether by GET or POST method.  A file upload field will return the
file content as the value here, it is left to the application code
to write this out to a file if that is required.

**htmlResponse** *html*  
Sets the literal html supplied as the response to be sent when the handler returns.

**dataResponse** *data type*  
Sets the literal data supplied as the response to be sent, with the specified mime type.

**fileResponse** *path ?type?*  
Sets the content of the file named by path as the response to be sent.  If the mime type is not specified it will be deduced from the file extension.

**cacheMaxAge** *seconds*  
Sets the cache-control header of the response to specify that the content returned
may be cached for not more than the specified number of seconds.

**setHeader** *name value*  
Sets the named header in the response to the given value.

**errorResponse** *code ?detail?*  
Sets the response to report an error with the specified error code, and optionally
adds the html in *detail* to give further information.

**redirect** *newurl*  
Sets the response to tell the client to redirect to the specified URL.

**setLogField** *field value*  
The first three fields in the access log are named remote, ident and user.
The `remote` field will default to the IP address of the source of the request, if this is available.  The `ident` and `user` fields have no default value.
This method allows the application to set the specified log field to the given value.

**scgi** *host port ?name value ...?*  
Forward the request to a program which provides an SCGI interface on the
specified host and port.  Additional argument pairs of name and value
can be supplied to set or override headers in the SCGI request.
The HTTP response will then be set from the SCGI response.


## Example

Start a web server on port 8080 which
- dynamically generates its home page, inserting the current time;
- serves any files placed in the htdocs subdirectory;
- returns a 404 error for other cases.

```tcl
package require wibbly

proc myhandler wob {
    set path [$wob getPath]
    if {$path eq "/"} {
        $wob htmlResponse "<h1>Hello World</h1>The time is [clock format now]"
    } elseif {[file isfile htdocs$path]} {
        $wob fileResponse htdocs$path
    } else {
        $wob errorResponse 404
    }
}

::wibbly::serve -handler myhandler

vwait forever
```

