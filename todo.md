# Security Review TODO - Analysis vs. Current Codebase

This document reviews the security findings from the comprehensive security audit against the actual current state of the codebase to identify what has been truly fixed versus what remains unaddressed.

## Analysis Summary

After reviewing the latest commit (8f352af4dcfeb6bfe90cf35ebbfc155f460ffde1) and comparing against the security review, **NONE of the issues marked as "FIXED ✅" have actually been implemented**. The security review appears to be aspirational rather than reflecting actual code changes.

## Critical Findings Status

### 1. HTML Injection via Article Markup System ❌ **NOT FIXED**

**Claimed Status**: FIXED ✅  
**Actual Status**: VULNERABLE  
**Locations**: 
- Line 1323: `html "<a href='$tok_txt' target='_blank'>$tok_txt</a>"`
- Line 1352: `set html [subst $out]`

**Issue**: Direct URL output without validation and dangerous `subst` command usage still present.

**Required Actions**:
- [ ] Add URL validation with scheme filtering (allow only http/https)
- [ ] Replace dangerous `subst` with safe template processing
- [ ] Add proper HTML attribute encoding for `$tok_txt`

### 2. Unvalidated URL Parameters in Links ❌ **NOT FIXED**

**Claimed Status**: FIXED ✅  
**Actual Status**: VULNERABLE  
**Locations**:
- Line 827: `html "<td><a$id href=$start_num$tail>[enpre $sub]</a></td>"`
- Line 1953: `html "<td><a$id href=$num>[enpre $sub]</a></td>"`

**Issue**: URL parameters (`$start_num`, `$num`) inserted directly into href attributes without validation.

**Required Actions**:
- [ ] Add HTML attribute encoding for all href values
- [ ] Validate numeric parameters before insertion
- [ ] Implement proper URL construction with encoding

### 3. CSS Color Injection ❌ **NOT FIXED**

**Claimed Status**: FIXED ✅  
**Actual Status**: VULNERABLE  
**Locations**: Lines 41-46
```tcl
body {color:$gen_fg; background-color: $gen_bg; font-family: Verdana}
.new {color:$new_fg; background-color: $new_bg}
.rep {color:$rep_fg; background-color: $rep_bg}
.quot {color: $quo_fg; background-color: $quo_bg}
```

**Issue**: User preference colors inserted directly into CSS without validation.

**Required Actions**:
- [ ] Add CSS color validation with hex pattern `^#[0-9a-fA-F]{3,6}$`
- [ ] Implement named color allowlisting
- [ ] Reject CSS values containing parentheses, quotes, or other dangerous characters

## Medium Priority Issues

### 4. Insufficient Input Validation in Forms ❌ **NOT ADDRESSED**

**Status**: Still present throughout codebase  
**Issue**: Form inputs undergo minimal validation (only string trimming)

**Required Actions**:
- [ ] Add length limits for all form inputs
- [ ] Implement character set restrictions where appropriate
- [ ] Add CSRF protection to state-changing forms

### 5. Path Traversal Prevention ❌ **NOT ADDRESSED**

**Status**: Current implementation has some protection but could be enhanced  
**Location**: Lines 209, 197-215

**Required Actions**:
- [ ] Add explicit checks for ".." sequences
- [ ] Use absolute path resolution for file serving
- [ ] Implement file extension whitelist

## Code Quality Issues Analysis

### Issue #19: TSV Memory Leaks ✅ **CONFIRMED REAL ISSUE**

**Status**: CONFIRMED - This is a legitimate concern  
**Locations**: Lines 1231, 1235, 1237, 2389
```tcl
tsv::set Faces $addr [binary decode base64 $facedata]
tsv::set Faces $addr {}
tsv::set Faces $addr $png
```

**Problem**: The TSV (Thread Shared Variables) `Faces` array grows unbounded as new email addresses are encountered. Face data (potentially large binary images) is stored indefinitely without any cleanup mechanism.

**Impact**: 
- Memory consumption grows without bounds in long-running processes
- Could lead to memory exhaustion over time
- No mechanism to remove old/unused face data

**Required Actions**:
- [ ] Implement TSV cleanup policy with size limits
- [ ] Add TTL (time-to-live) for face data entries
- [ ] Implement LRU (Least Recently Used) eviction strategy
- [ ] Add monitoring for TSV memory usage

**Explanation of Issue #19**: This is indeed a real problem. The application stores decoded face images in thread-shared memory indefinitely. In a long-running web server, this will cause unbounded memory growth as new email addresses are encountered in newsgroup posts. Each face can be several KB of binary data, and with no cleanup mechanism, memory usage will only increase over time.

### Other Confirmed Code Quality Issues

#### Random File Generation DoS Risk
**Location**: Line 254
```tcl
exec head -[expr {int(rand()*100000)}]c /dev/urandom > htdocs/random
```
**Issue**: Could generate up to 100KB files repeatedly, potential disk DoS
**Action Required**: [ ] Add reasonable upper limits and disk space checks

#### Race Condition in NNTP Name Generation
**Location**: `scripts/nntp.tcl` lines 77-84 (referenced)
**Issue**: Counter reset creates potential race condition
**Action Required**: [ ] Use global counter or better unique ID generation

## Enhanced HTML Encoding Required

### Current `enpre` Function Analysis
**Location**: Line 1109
```tcl
proc enpre {str} {
    string map {< &lt; > &gt; & &amp; \" &quot; \r "" ' &#39;} $str
}
```

**Issues**:
- Missing backslash escaping
- No newline handling
- Not context-aware for different output contexts

**Required Actions**:
- [ ] Update `enpre` to handle additional vectors (backslash, newlines)
- [ ] Create context-specific encoding functions:
  - `html_encode` for HTML content
  - `attr_encode` for HTML attributes
  - `url_encode` for URLs
  - `css_encode` for CSS values

## Database Security Status ✅ **ACTUALLY SECURE**

**Good News**: The database security assessment in the review is accurate. All SQL queries use proper parameterization:
```tcl
userdb eval {SELECT num FROM users WHERE email == $enc_email AND pass == $enc_pass}
userdb eval {UPDATE users SET params = $params WHERE num = $user}
```
No SQL injection vulnerabilities found in any of the 51+ SQL statements reviewed.

## Authentication Security Issues

### MD5 Password Hashing ❌ **CONFIRMED VULNERABLE**
**Status**: Still using MD5-based authentication  
**Locations**: Lines 333-336, 372-376 in server/news_code.tcl; lines 42, 89-90 in scripts/user_admin

**Issue**: Uses `md5crypt::md5crypt` which, while salted, is still cryptographically weak
**Action Required**: [ ] Migrate to bcrypt, scrypt, or Argon2

## Recommended Implementation Order

### Phase 1 (Critical - Immediate Action Required)
1. [ ] Fix URL validation in markup system (line 1323)
2. [ ] Replace dangerous `subst` command (line 1352)  
3. [ ] Add HTML attribute encoding for href values (lines 827, 1953)
4. [ ] Implement CSS color validation (lines 41-46)

### Phase 2 (High Priority - 1-2 Weeks)
1. [ ] Implement TSV cleanup policy for Face data
2. [ ] Add comprehensive input validation framework
3. [ ] Enhance HTML encoding functions with context awareness
4. [ ] Add resource limits for random file generation

### Phase 3 (Medium Priority - 1 Month)
1. [ ] Upgrade password hashing to modern algorithms
2. [ ] Implement CSRF protection
3. [ ] Add proper error handling and logging
4. [ ] Establish coding standards and security review process

## Conclusion

**The security review document appears to be a template or wishlist rather than a reflection of actual fixes.** All critical vulnerabilities remain unaddressed in the current codebase. Issue #19 (TSV memory leaks) is confirmed as a legitimate concern requiring attention.

**Priority**: Address Phase 1 items immediately as they represent active XSS vulnerabilities that could compromise user security.