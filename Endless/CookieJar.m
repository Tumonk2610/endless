#import "AppDelegate.h"
#import "CookieJar.h"
#import "HTTPSEverywhere.h"

/*
 * local storage is found in NSCachesDirectory and can be a file or directory:
 *
 * ./AppData/Library/Caches/https_m.imgur.com_0.localstorage
 * ./AppData/Library/Caches/https_m.youtube.com_0.localstorage
 * ./AppData/Library/Caches/http_samy.pl_0
 * ./AppData/Library/Caches/http_samy.pl_0/.lock
 * ./AppData/Library/Caches/http_samy.pl_0/0000000000000001.db
 * ./AppData/Library/Caches/http_samy.pl_0.localstorage
 */

#define LOCAL_STORAGE_REGEX @"/https?_(.+)_\\d+(\\.localstorage)?$"

@implementation CookieJar

AppDelegate *appDelegate;

+ (NSString *)cookieWhitelistPath
{
	NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
	return [path stringByAppendingPathComponent:@"cookie_whitelist.plist"];
}

- (CookieJar *)init
{
	self = [super init];
	
	appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];

	_cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
	[_cookieStorage setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain];

	_dataAccesses = [[NSMutableDictionary alloc] init];
	
	NSFileManager *fileManager = [NSFileManager defaultManager];
	if ([fileManager fileExistsAtPath:[[self class] cookieWhitelistPath]]) {
		_whitelist = [NSMutableDictionary dictionaryWithContentsOfFile:[[self class] cookieWhitelistPath]];
	}
	else {
		_whitelist = [[NSMutableDictionary alloc] initWithCapacity:20];
	}
	
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	[self setOldDataSweepTimeout:[NSNumber numberWithInteger:[userDefaults integerForKey:@"old_data_sweep_mins"]]];
	
	return self;
}

- (void)persist
{
	[[self whitelist] writeToFile:[[self class] cookieWhitelistPath] atomically:YES];
}

- (BOOL)isHostWhitelisted:(NSString *)host
{
	host = [host lowercaseString];
	
	if ([[self whitelist] objectForKey:host]) {
#ifdef TRACE_COOKIE_WHITELIST
		NSLog(@"[CookieJar] found entry for %@", host);
#endif
		return YES;
	}
	
	/* for a cookie host of x.y.z.example.com, try y.z.example.com, z.example.com, example.com, etc. */
	NSArray *hostp = [host componentsSeparatedByString:@"."];
	for (int i = 1; i < [hostp count]; i++) {
		NSString *wc = [[hostp subarrayWithRange:NSMakeRange(i, [hostp count] - i)] componentsJoinedByString:@"."];
		
		if ([[self whitelist] objectForKey:wc]) {
#ifdef TRACE_COOKIE_WHITELIST
			NSLog(@"[CookieJar] found entry for component %@ in %@", wc, host);
#endif
			return YES;
		}
	}
	
	return NO;
}

- (NSArray *)whitelistedHosts
{
	return [NSArray arrayWithArray:[[[self whitelist] allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]];
}

- (NSArray *)sortedHostCounts
{
	NSMutableDictionary *cHostCount = [[NSMutableDictionary alloc] init];
	NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^\\." options:0 error:nil];
	NSMutableArray *sortedCookieHosts;
	
	for (NSHTTPCookie *c in [[self cookieStorage] cookies]) {
		/* strip off leading . */
		NSString *cdomain = [regex stringByReplacingMatchesInString:[c domain] options:0 range:NSMakeRange(0, [[c domain] length]) withTemplate:@""];
		
		NSNumber *count = @0;

		NSDictionary *cct = [cHostCount objectForKey:cdomain];
		if (cct)
			count = [cct objectForKey:@"cookies"];
		
		[cHostCount setObject:@{ @"cookies" : [NSNumber numberWithInt:[count intValue] + 1] } forKey:cdomain];
	}
	
	/* mix in localstorage */
	for (NSString *host in [self localStorageHosts]) {
		[cHostCount setObject:@{ @"localStorage" : [NSNumber numberWithInt:1] } forKey:host];
	}

	sortedCookieHosts = [[NSMutableArray alloc] initWithCapacity:[cHostCount count]];
	for (NSString *cdomain in [[cHostCount allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
		[sortedCookieHosts addObject:@{ cdomain : [cHostCount objectForKey:cdomain] }];
	}
	
	return sortedCookieHosts;
}

- (NSDictionary *)localStorageFiles
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
	
	NSMutableDictionary *files = [[NSMutableDictionary alloc] init];
	
	NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:LOCAL_STORAGE_REGEX options:0 error:nil];
	
	for (NSString *file in [fm contentsOfDirectoryAtPath:cacheDir error:nil]) {
		NSString *absFile = [NSString stringWithFormat:@"%@/%@", cacheDir, file];
		
		NSArray *matches = [regex matchesInString:absFile options:0 range:NSMakeRange(0, [absFile length])];
		if (!matches || ![matches count]) {
			continue;
		}
		
		for (NSTextCheckingResult *match in matches) {
			if ([match numberOfRanges] >= 1) {
				NSString *host = [absFile substringWithRange:[match rangeAtIndex:1]];
				[files setObject:host forKey:absFile];
			}
		}
	}
	
	return files;
}

- (NSArray *)localStorageHosts
{
	NSMutableArray *hosts = [[NSMutableArray alloc] init];
	NSDictionary *files = [self localStorageFiles];
	
	for (NSString *file in [files allKeys]) {
		NSString *host = [files objectForKey:file];
		
		if (![hosts containsObject:host]) {
			[hosts addObject:host];
		}
	}

	return [hosts sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
}

/* swap out entire whitelist */
- (void)updateWhitelistedHostsWithArray:(NSArray *)hosts
{
	for (NSString *host in hosts) {
		if (![[self whitelist] objectForKey:host]) {
			[[self whitelist] setValue:@YES forKey:[host lowercaseString]];
		}
	}
	
	for (NSString *host in [[self whitelist] allKeys]) {
		if ([hosts indexOfObject:host] == NSNotFound) {
			[[self whitelist] removeObjectForKey:host];
		}
	}
}

- (NSArray *)cookiesForURL:(NSURL *)url forTab:(NSUInteger)tabHash
{
	NSArray *c = [[self cookieStorage] cookiesForURL:url];
	
	for (NSHTTPCookie *cookie in c) {
		[self trackDataAccessForDomain:[cookie domain] fromTab:tabHash];
	}

	return c;
}

- (void)setCookies:(NSArray *)cookies forURL:(NSURL *)URL mainDocumentURL:(NSURL *)mainDocumentURL forTab:(NSUInteger)tabHash
{
	NSMutableArray *newCookies = [[NSMutableArray alloc] initWithCapacity:[cookies count]];
	
	for (NSHTTPCookie *cookie in cookies) {
		NSMutableDictionary *ps = (NSMutableDictionary *)[cookie properties];
		
		if (![cookie isSecure] && [HTTPSEverywhere needsSecureCookieFromHost:[URL host] forHost:[cookie domain] cookieName:[cookie name]]) {
			/* toggle "secure" bit */
			[ps setValue:@"TRUE" forKey:NSHTTPCookieSecure];
		}
		
		if (![[appDelegate cookieJar] isHostWhitelisted:[URL host]]) {
			/* host isn't whitelisted, force to a session cookie */
			[ps setValue:@"TRUE" forKey:NSHTTPCookieDiscard];
		}
		
		NSHTTPCookie *nCookie = [[NSHTTPCookie alloc] initWithProperties:ps];
		[newCookies addObject:nCookie];
		
		[self trackDataAccessForDomain:[cookie domain] fromTab:tabHash];
	}
	
	if ([newCookies count] > 0) {
#ifdef TRACE_COOKIES
		NSLog(@"[CookieJar] [Tab h%lu] storing %lu cookie(s) for %@ (via %@)", tabHash, [newCookies count], [URL host], mainDocumentURL);
#endif
		[[self cookieStorage] setCookies:newCookies forURL:URL mainDocumentURL:mainDocumentURL];
	}
}

- (void)trackDataAccessForDomain:(NSString *)domain fromTab:(NSUInteger)tabHash
{
	NSNumber *tabHashN = [NSNumber numberWithLong:tabHash];
	
	if (![[self dataAccesses] objectForKey:tabHashN]) {
		[[self dataAccesses] setObject:[[NSMutableDictionary alloc] init] forKey:tabHashN];
	}
	
	[(NSMutableDictionary *)[[self dataAccesses] objectForKey:tabHashN] setObject:[NSDate date] forKey:domain];
	
#ifdef TRACE_COOKIES
	NSLog(@"[CookieJar] [Tab h%lu] touched data access for %@", tabHash, domain);
#endif
}

/* ignores whitelist, this is forced by the user */
- (void)clearAllDataForHost:(NSString *)host
{
	for (NSHTTPCookie *cookie in [[self cookieStorage] cookies]) {
		if ([[cookie domain] isEqualToString:host] || [[cookie domain] isEqualToString:[NSString stringWithFormat:@".%@", host]]) {
#ifdef TRACE_COOKIES
			NSLog(@"[CookieJar] deleting cookie for %@: %@", host, cookie);
#endif
			[[self cookieStorage] deleteCookie:cookie];
		}
	}
	
	NSDictionary *files = [self localStorageFiles];
	for (NSString *file in [files allKeys]) {
		NSString *fhost = [files objectForKey:file];
		
		if ([host isEqualToString:fhost]) {
#ifdef TRACE_COOKIES
			NSLog(@"[CookieJar] deleting local storage for %@: %@", host, file);
#endif
			[[NSFileManager defaultManager] removeItemAtPath:file error:nil];
		}
	}
}

- (void)clearAllNonWhitelistedCookiesOlderThan:(NSTimeInterval)secs
{
	for (NSHTTPCookie *cookie in [[self cookieStorage] cookies]) {
		if ([self isHostWhitelisted:[cookie domain]]) {
			continue;
		}
		
		NSNumber *blocker;
		
		if (secs > 0) {
			for (NSNumber *tabHashN in [[self dataAccesses] allKeys]) {
				NSMutableDictionary *tabCookies = [[self dataAccesses] objectForKey:tabHashN];
				NSDate *la = [tabCookies objectForKey:[cookie domain]];
				if (la != nil || [[NSDate date] timeIntervalSinceDate:la] < secs) {
					blocker = tabHashN;
					break;
				}
			}
		}

		if (secs == 0 || blocker == nil) {
#ifdef TRACE_COOKIE_WHITELIST
			NSLog(@"[CookieJar] deleting non-whitelisted cookie: %@", cookie);
#endif
			[[self cookieStorage] deleteCookie:cookie];
		}
	}
}

- (void)clearAllNonWhitelistedLocalStorageOlderThan:(NSTimeInterval)secs
{
	NSDictionary *files = [self localStorageFiles];
	for (NSString *file in [files allKeys]) {
		NSString *fhost = [files objectForKey:file];
		
		if ([self isHostWhitelisted:fhost]) {
			continue;
		}

		NSNumber *blocker;
		
		if (secs > 0) {
			for (NSNumber *tabHashN in [[self dataAccesses] allKeys]) {
				NSMutableDictionary *tabData = [[self dataAccesses] objectForKey:tabHashN];
				NSDate *la = [tabData objectForKey:fhost];
				if (la != nil || [[NSDate date] timeIntervalSinceDate:la] < secs) {
					blocker = tabHashN;
					break;
				}
			}
		}
		
		if (secs == 0 || blocker == nil) {
#ifdef TRACE_COOKIES
			NSLog(@"[CookieJar] deleting local storage for %@: %@", fhost, file);
#endif
			[[NSFileManager defaultManager] removeItemAtPath:file error:nil];
		}
	}
}

- (void)clearAllNonWhitelistedData
{
	[self clearAllNonWhitelistedCookiesOlderThan:0];
	[self clearAllNonWhitelistedLocalStorageOlderThan:0];
}

- (void)clearAllOldNonWhitelistedData
{
	int sweepmins = [[self oldDataSweepTimeout] intValue];
	
#ifdef TRACE_COOKIES
	NSLog(@"[CookieJar] clearing non-whitelisted data older than %d min(s)", sweepmins);
#endif
	[self clearAllNonWhitelistedCookiesOlderThan:(60 * sweepmins)];
	[self clearAllNonWhitelistedLocalStorageOlderThan:(60 * sweepmins)];
}


- (void)clearNonWhitelistedDataForTab:(NSUInteger)tabHash
{
	NSNumber *tabHashN = [NSNumber numberWithLong:tabHash];

#ifdef TRACE_COOKIES
	NSLog(@"[Tab h%@] clearing non-whitelisted data", tabHashN);
#endif
	
	for (NSString *cookieDomain in [[[self dataAccesses] objectForKey:tabHashN] allKeys]) {
		NSNumber *blocker;

		for (NSNumber *otherTabHashN in [[self dataAccesses] allKeys]) {
			if ([otherTabHashN isEqual:tabHashN]) {
				continue;
			}
			
			NSMutableDictionary *tabCookies = [[self dataAccesses] objectForKey:otherTabHashN];
			
			if ([tabCookies objectForKey:cookieDomain]) {
				blocker = otherTabHashN;
				break;
			}
		}
		
		if (blocker) {
#ifdef TRACE_COOKIES
			NSLog(@"[Tab h%@] data for %@ in use on tab %@, not deleting", tabHashN, cookieDomain, blocker);
#endif
		}
		else if (![self isHostWhitelisted:cookieDomain]) {

#ifdef TRACE_COOKIES
			NSLog(@"[Tab h%@] deleting data for %@", tabHashN, cookieDomain);
#endif
			[self clearAllDataForHost:cookieDomain];
		}
	}
	
	[[self dataAccesses] removeObjectForKey:tabHashN];
}

@end