# Copilot Instructions for Newsgrouper

## Project Overview

Newsgrouper is a Tcl-based web interface to Usenet newsgroups that provides modern web access to traditional NNTP newsgroup content. The application allows users to browse, read, and post to newsgroups through a web browser.

**Key Information:**
- Language: Tcl (version 9.0 required)
- Web Server: Tclhttpd (customized with Tcl modules)
- Architecture: Multi-process system with caching via Redis
- License: ISC License
- Repository: https://github.com/go-while/newsgrouper

## Architecture Overview

### Core Components

1. **Web Server (`server/` directory)**
   - `news_code.tcl` - Main web application logic, generates HTML pages
   - `hacks.tcl` - Server customizations and extensions
   - `mypage.tcl` - Additional page handling
   - Entry point: `start` script runs `tclsh9.0 tclhttpd3.5/bin/httpd.tcl`

2. **Backend Processes (`scripts/` directory)**
   - `newsgetter` - NNTP client processes (up to 4 per server for concurrent connections)
   - `newsutility` - Handles X-Face images, group charters, archive search, statistics
   - `newshub` - Additional coordination process

3. **Library Code (`scripts/` directory)**
   - `nntp.tcl` - NNTP protocol implementation
   - `distcl.tcl` - DisTcl distributed system coordination
   - `retcl.tm` - Redis interface for Tcl
   - Various database and utility scripts

4. **Static Content (`htdocs/` directory)**
   - HTML help pages, icons, images
   - CSS styling embedded in Tcl code

### Data Storage

- **Redis**: Caching, process coordination, session data, newsgroup lists
- **SQLite**: User accounts, preferences, and authentication (`user_db`)
- **File System**: Archive files, overview databases (`over_db`, `arch_db`)

## Prerequisites and Dependencies

### Required Software
- **Tcl 9.0** (currently has 8.6.14, needs upgrade)
- **Tk** (for user_admin GUI tool)
- **Tcllib** (Tcl standard library)
- **Tclhttpd** (Tcl HTTP server)
- **TclTls** (for HTTPS support)
- **Retcl** (Tcl interface to Redis)
- **Tclsqlite** (Tcl interface to SQLite)
- **Redis** (or compatible fork)

### Optional Dependencies
- **NNTP server access** (for newsgroup content)
- **UUCP setup** (for posting via UUCP)
- **uncompface** (for X-Face support, package: compface)
- **mboxgrep** (for archive search, package: mboxgrep)

## Build/Setup Process

### Initial Setup

1. **Install Dependencies**
   ```bash
   # Debian/Ubuntu example
   sudo apt-get install tcl9.0 tcl9.0-dev tcllib tk redis-server sqlite3
   sudo apt-get install compface mboxgrep  # optional
   # Install Tclhttpd, TclTls, Retcl, Tclsqlite separately
   ```

2. **Configuration Files**
   Copy and customize sample configuration files:
   ```bash
   cd scripts/
   cp ng_config.tcl.sample ng_config.tcl
   cp na_config.tcl.sample na_config.tcl  
   cp nu_config.tcl.sample nu_config.tcl
   ```

3. **Edit Configuration**
   Update `scripts/ng_config.tcl` with:
   - `this_site` - Your domain name
   - `admin_email` - Administrator email
   - `user_db` - Path to SQLite user database
   - `nntp_server`, `nntp_user`, `nntp_pass` - NNTP server credentials
   - `over_db`, `arch_db` - Paths for overview and archive databases
   - `blocked_groups` - Groups to filter out

4. **Database Initialization**
   ```bash
   # Create user database
   tclsh9.0 scripts/db_create.tcl
   
   # Add users via GUI (requires X11/display)
   tclsh9.0 scripts/user_admin
   
   # Initialize newsgroup list (requires NNTP access)
   tclsh9.0 scripts/newslist
   ```

5. **Start Services**
   ```bash
   # Start Redis
   redis-server &
   
   # Start backend processes
   tclsh9.0 scripts/newsgetter &
   tclsh9.0 scripts/newsutility &
   
   # Start web server
   ./start
   ```

### Running the Application

- **Start Script**: `./start` launches the web server
- **Default Access**: Web interface typically available on configured port
- **Logs**: Check Tclhttpd logs for debugging
- **Monitoring**: Use Redis CLI to inspect cached data

## Development Guidelines

### Code Organization

1. **Web Layer** (`server/news_code.tcl`)
   - URL routing via `Url_PrefixInstall`
   - HTML generation functions
   - User session management
   - Page rendering logic

2. **Business Logic**
   - NNTP operations in `scripts/nntp.tcl`
   - Database operations in various `db_*` scripts
   - Distributed coordination in `scripts/distcl.tcl`

3. **Configuration**
   - All configurations in `scripts/*_config.tcl` files
   - Sample configurations provided for reference
   - Sensitive data (passwords) kept in config files

### Coding Conventions

- **Tcl Style**: Follow standard Tcl conventions
- **HTML Generation**: Use `html` command for string building
- **Error Handling**: Use `catch` for error management
- **Namespaces**: Minimal use, mostly global scope
- **Documentation**: Comments in Tcl code, extensive README

### Key Files for Modification

- `server/news_code.tcl` - Main application logic
- `scripts/ng_config.tcl` - Primary configuration
- `scripts/nntp.tcl` - NNTP protocol handling
- `scripts/distcl.tcl` - Process coordination
- `htdocs/*.htm` - Static help pages

## Testing and Debugging

### Manual Testing
1. **Web Interface**: Browse to configured URL
2. **User Functions**: Test login, preferences, posting
3. **Newsgroup Access**: Verify group lists, article retrieval
4. **Backend Processes**: Check Redis for cached data

### Debugging Techniques
- **Tcl Debug**: Add `puts` statements for debugging
- **Redis Inspection**: Use `redis-cli` to examine cache
- **Log Files**: Check Tclhttpd access and error logs
- **Process Monitoring**: Ensure all backend processes running

### Common Issues
- **Tcl Version**: Ensure Tcl 9.0 is used (currently 8.6.14)
- **Dependencies**: Verify all Tcl packages are installed
- **Configuration**: Check all paths and credentials in config files
- **Permissions**: Ensure database and log file permissions
- **Network**: Verify NNTP server connectivity

## Security Considerations

- **User Authentication**: SQLite-based with MD5 password hashing (MD5 is cryptographically insecure and vulnerable to rainbow table attacks; migration to a secure password hashing algorithm such as bcrypt, scrypt, or Argon2 is strongly recommended)
- **Session Management**: Redis-based session storage
- **Input Validation**: Validate all user inputs in web forms
- **Configuration**: Keep sensitive data in config files, not code
- **Access Control**: Implement proper user permissions

## Performance and Scaling

- **Caching**: Heavy use of Redis for performance
- **Concurrent Connections**: Up to 4 NNTP connections per server
- **Process Architecture**: Separate processes for different functions
- **Database Optimization**: SQLite for user data, Redis for session/cache

## Common Development Tasks

### Adding New Features
1. Identify which component needs modification
2. Update configuration if needed
3. Modify appropriate Tcl files
4. Test with manual verification
5. Update documentation

### Troubleshooting
1. Check Redis connection and data
2. Verify NNTP server connectivity
3. Review Tclhttpd logs
4. Validate configuration files
5. Ensure all processes are running

### Performance Tuning
1. Monitor Redis memory usage
2. Optimize database queries
3. Adjust caching timeouts
4. Balance NNTP connection load

## Quick Setup Validation

To verify the setup process described above:

```bash
# Check Tcl version (should be 9.0, currently 8.6.14)
echo 'puts [info patchlevel]; exit' | tclsh

# Verify key files exist
ls -la start scripts/ng_config.tcl.sample server/news_code.tcl

# Check Redis availability (if installed)
which redis-server || echo "Redis not installed"

# Test that configuration samples are readable
head -3 scripts/ng_config.tcl.sample
head -3 scripts/na_config.tcl.sample  
head -3 scripts/nu_config.tcl.sample

# Verify start script points to correct Tcl version
cat start
```

**Expected Issues in Current Environment:**
- Tcl version is 8.6.14 but 9.0 is required
- Missing Tclhttpd, Redis, and other dependencies
- Configuration files need to be copied from samples and customized

## Current Repository State

**Environment Analysis (as of file creation):**
- Tcl Version: 8.6.14 (requires upgrade to 9.0)
- Missing Dependencies: Redis, Tclhttpd, TclTls, Retcl, etc.
- Configuration: Sample files present, need customization
- Database: SQLite creation script available (`scripts/db_create.tcl`)
- Status: Requires significant environment setup before running

**Immediate Setup Tasks:**
1. Upgrade to Tcl 9.0
2. Install missing Tcl packages and dependencies  
3. Copy and customize configuration files
4. Install and configure Redis
5. Set up NNTP server access
6. Initialize databases

## Notes for AI Development

- **No Compilation**: This is an interpreted Tcl application
- **Minimal Changes**: Focus on configuration and small code modifications  
- **Testing**: Primarily manual testing through web interface
- **Dependencies**: Be aware of complex Tcl package requirements
- **Architecture**: Multi-process design requires understanding of DisTcl system
- **Current State**: Repository has Tcl 8.6.14 but requires 9.0 upgrade
- **Configuration First**: Always set up config files before running any scripts
- **Production Ready**: Code appears mature but requires proper environment setup.