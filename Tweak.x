#import <UIKit/UIKit.h>

// Safari's User-Agent for this device's iOS version (Reddit blocks requests
static NSString *TLUserAgent(void) {
	NSArray<NSString *> *v = [UIDevice.currentDevice.systemVersion componentsSeparatedByString:@"."];
	NSString *os = [v componentsJoinedByString:@"_"];
	NSString *version = v.count > 1 ? [NSString stringWithFormat:@"%@.%@", v[0], v[1]] : v[0];
	return [NSString stringWithFormat:@"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/%@ Mobile/15E148 Safari/604.1", os, version];
}

#pragma mark - Hosts

static BOOL TLHostIs(NSString *host, NSString *domain) {
	host = host.lowercaseString;
	return [host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]];
}

static BOOL TLIsGoogleHost(NSString *host) {
	host = host.lowercaseString;
	return [host hasPrefix:@"google."] || [host rangeOfString:@".google."].location != NSNotFound;
}

static BOOL TLIsAmazonHost(NSString *host) {
	host = host.lowercaseString;
	return [host hasPrefix:@"amazon."] || [host rangeOfString:@".amazon."].location != NSNotFound;
}

static BOOL TLIsHTTP(NSString *s) {
	s = s.lowercaseString;
	return [s hasPrefix:@"http://"] || [s hasPrefix:@"https://"];
}

static NSString *TLQueryValue(NSURL *url, NSString *name) {
	NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
	for (NSURLQueryItem *item in c.queryItems)
		if ([item.name isEqualToString:name]) return item.value;
	return nil;
}

#pragma mark - Short links (need network)

static BOOL TLIsGotoURL(NSURL *url) {
	if (!url || !TLIsGoogleHost(url.host)) return NO;
	if (![url.path isEqualToString:@"/goto"]) return NO;
	NSString *v = TLQueryValue(url, @"url");
	return v.length && !TLIsHTTP(v); // "url=https://..." is plain, unwrapped locally
}

// Reddit app share links: reddit.com/r/<sub>/s/<code> (also /u/<user>/s/...).
static BOOL TLIsRedditShareURL(NSURL *url) {
	if (!url) return NO;
	NSString *host = url.host.lowercaseString;
	if (!([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"])) return NO;
	static NSRegularExpression *re;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		re = [NSRegularExpression regularExpressionWithPattern:@"^/(?:r|u|user)/[^/]+/s/[A-Za-z0-9]+/?$" options:NSRegularExpressionCaseInsensitive error:nil];
	});
	NSString *path = url.path ?: @"";
	return [re firstMatchInString:path options:0 range:NSMakeRange(0, path.length)] != nil;
}

// Amazon short links: amzn.to/<code>.
static BOOL TLIsAmznShortURL(NSURL *url) {
	return url && TLHostIs(url.host, @"amzn.to") && url.path.length > 1;
}

static BOOL TLIsShortLink(NSURL *url) {
	return TLIsGotoURL(url) || TLIsRedditShareURL(url) || TLIsAmznShortURL(url);
}

// Unknown codes redirect to a generic page instead of failing: Reddit to the
// bare community (/r/<sub>/), amzn.to to the Amazon home page. Treat those as
// "not resolved" rather than replacing the link with something useless.
static BOOL TLIsFallbackRedirect(NSURL *from, NSURL *to) {
	if (to.query.length) return NO;
	if (TLIsRedditShareURL(from)) return to.pathComponents.count <= 3; // "/", "r", "<sub>"
	if (TLIsAmznShortURL(from)) return to.pathComponents.count <= 1;  // "/" or none
	return NO;
}

@interface TLNoRedirectDelegate : NSObject <NSURLSessionTaskDelegate>
@end

@implementation TLNoRedirectDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
	completionHandler(nil); // stop at the 302 so we can read Location
}
@end

static NSURLSession *TLSession(void) {
	static NSURLSession *session;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
		cfg.timeoutIntervalForRequest = 4;
		cfg.HTTPAdditionalHeaders = @{ @"User-Agent": TLUserAgent() };
		session = [NSURLSession sessionWithConfiguration:cfg delegate:[TLNoRedirectDelegate new] delegateQueue:nil];
	});
	return session;
}

static void TLResolve(NSString *shortLink, void (^done)(NSString *dest)) {
	NSURLComponents *c = [NSURLComponents componentsWithString:shortLink];
	c.scheme = @"https"; // old links are often http://, which ATS blocks in most apps
	NSURL *url = c.URL;
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
	req.HTTPMethod = @"GET"; // HEAD returns 200 without a Location header
	[[TLSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		NSString *dest = nil;
		if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
			NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
			NSString *loc = [http valueForHTTPHeaderField:@"Location"];
			if (http.statusCode >= 300 && http.statusCode < 400 && loc.length) {
				NSURL *d = [NSURL URLWithString:loc relativeToURL:url].absoluteURL;
				if (TLIsHTTP(d.absoluteString) && !TLIsShortLink(d) && !TLIsFallbackRedirect(url, d)) dest = d.absoluteString;
			}
		}
		done(dest);
	}] resume];
}

#pragma mark - Local cleaning

// Destination carried in plain text by a known redirect wrapper, or nil.
static NSString *TLUnwrapRedirect(NSURL *url) {
	NSString *host = url.host.lowercaseString;
	NSArray<NSString *> *keys = nil;
	if (TLIsGoogleHost(host) && ([url.path isEqualToString:@"/url"] || [url.path isEqualToString:@"/goto"]))
		keys = @[ @"url", @"q" ];
	else if ([host isEqualToString:@"l.facebook.com"] || [host isEqualToString:@"lm.facebook.com"])
		keys = @[ @"u" ];
	else if ([host isEqualToString:@"www.googleadservices.com"])
		keys = @[ @"adurl", @"ds_dest_url" ];
	else if (TLHostIs(host, @"lnkd.in") || (TLHostIs(host, @"linkedin.com") && [url.path hasPrefix:@"/redir"]))
		keys = @[ @"url" ];
	for (NSString *k in keys) {
		NSString *v = TLQueryValue(url, k);
		if (TLIsHTTP(v)) return v;
	}
	return nil;
}

static BOOL TLIsTrackingParam(NSString *name, NSString *host) {
	static NSSet<NSString *> *general, *google, *facebook, *x, *reddit, *linkedin, *threads, *spotify;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		general = [NSSet setWithArray:@[
			@"fbclid", @"gclid", @"gbraid", @"wbraid", @"dclid", @"msclkid", @"igshid", @"igsh",
			@"mc_cid", @"mc_eid", @"mkt_tok", @"vero_id", @"yclid", @"srsltid", @"ttclid", @"twclid",
			@"_hsenc", @"_hsmi", @"hsctatracking", @"_ga", @"_gl", @"oly_enc_id", @"oly_anon_id",
			@"li_fat_id", @"sc_campaign", @"sc_channel", @"sc_content", @"sc_country", @"sc_geo",
			@"sc_medium", @"sc_outcome",
		]];
		google = [NSSet setWithArray:@[ @"ved", @"usg", @"opi", @"rct", @"ei", @"sca_esv", @"sca_upv" ]];
		facebook = [NSSet setWithArray:@[ @"mibextid", @"rdid", @"sfnsn", @"ref", @"__tn__", @"eav", @"paipv", @"extid" ]];
		x = [NSSet setWithArray:@[ @"s", @"t", @"ref_src", @"ref_url" ]];
		reddit = [NSSet setWithArray:@[
			@"share_id", @"rdt", @"ref", @"ref_source", @"ref_campaign", @"correlation_id",
			@"post_fullname", @"post_index", @"$deep_link", @"$3p", @"_branch_match_id", @"_branch_referrer",
		]];
		linkedin = [NSSet setWithArray:@[ @"trackingid", @"refid", @"lipi", @"midtoken", @"midsig", @"trkemail", @"eid", @"rcm" ]];
		threads = [NSSet setWithArray:@[ @"xmt", @"slof" ]];
		spotify = [NSSet setWithArray:@[ @"si", @"nd", @"dlsi", @"pi", @"pt" ]];
	});
	NSString *n = name.lowercaseString;
	if ([n hasPrefix:@"utm_"] || [general containsObject:n]) return YES;

	if (TLHostIs(host, @"youtube.com") || TLHostIs(host, @"youtu.be")) // keep only playback params
		return ![@[ @"v", @"t", @"start", @"list" ] containsObject:n];
	if (TLIsGoogleHost(host))
		return [google containsObject:n];
	if (TLHostIs(host, @"facebook.com") || TLHostIs(host, @"fb.com") || TLHostIs(host, @"fb.watch"))
		return [facebook containsObject:n] || [n hasPrefix:@"__cft__"] || [n hasPrefix:@"__xts__"];
	if (TLHostIs(host, @"x.com") || TLHostIs(host, @"twitter.com"))
		return [x containsObject:n];
	if (TLHostIs(host, @"reddit.com") || TLHostIs(host, @"redd.it"))
		return [reddit containsObject:n];
	if (TLHostIs(host, @"instagram.com"))
		return [n isEqualToString:@"igsh"] || [n isEqualToString:@"img_index"];
	if (TLHostIs(host, @"threads.net") || TLHostIs(host, @"threads.com"))
		return [threads containsObject:n];
	if (TLHostIs(host, @"linkedin.com"))
		return [linkedin containsObject:n];
	if (TLHostIs(host, @"spotify.com"))
		return [spotify containsObject:n];
	if (TLIsAmazonHost(host))
		return [n hasPrefix:@"ref"] || [n hasPrefix:@"pd_rd_"] || [n hasPrefix:@"pf_rd_"] ||
		       [@[ @"tag", @"psc", @"content-id", @"keywords", @"qid", @"sr", @"crid", @"sprefix", @"th", @"linkcode", @"linkid", @"camp", @"creative" ] containsObject:n];
	return NO;
}

static NSString *TLCleanLink(NSString *link) {
	// Unwrap nested redirects (bounded, in case of loops).
	for (int i = 0; i < 4; i++) {
		NSURL *u = [NSURL URLWithString:link];
		NSString *inner = u ? TLUnwrapRedirect(u) : nil;
		if (!inner) break;
		link = inner;
	}

	NSURLComponents *c = [NSURLComponents componentsWithString:link];
	if (!c || !TLIsHTTP(link)) return link;
	NSString *host = c.host;

	// Amazon product pages: keep just /dp/<ASIN>.
	if (TLIsAmazonHost(host)) {
		static NSRegularExpression *asin;
		static dispatch_once_t once;
		dispatch_once(&once, ^{
			asin = [NSRegularExpression regularExpressionWithPattern:@"/(?:dp|gp/product)/([A-Z0-9]{10})(?:/|$)" options:0 error:nil];
		});
		NSString *path = c.percentEncodedPath ?: @"";
		NSTextCheckingResult *m = [asin firstMatchInString:path options:0 range:NSMakeRange(0, path.length)];
		if (m) {
			c.percentEncodedPath = [@"/dp/" stringByAppendingString:[path substringWithRange:[m rangeAtIndex:1]]];
			c.percentEncodedQuery = nil;
			c.fragment = nil;
			return c.string ?: link;
		}
	}

	NSArray<NSURLQueryItem *> *items = c.percentEncodedQueryItems;
	if (items.count == 0) return link;
	NSMutableArray<NSURLQueryItem *> *kept = [NSMutableArray array];
	for (NSURLQueryItem *item in items)
		if (!TLIsTrackingParam(item.name.stringByRemovingPercentEncoding ?: item.name, host)) [kept addObject:item];
	if (kept.count == items.count) return link;
	c.percentEncodedQueryItems = kept.count ? kept : nil;
	return c.string ?: link;
}

#pragma mark - Finding links

static NSArray<NSString *> *TLLinksInString(NSString *s) {
	if (s.length == 0) return @[];
	static NSRegularExpression *re;
	static NSCharacterSet *trailing;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		re = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s<>'\"]+" options:NSRegularExpressionCaseInsensitive error:nil];
		trailing = [NSCharacterSet characterSetWithCharactersInString:@".,;:!?)]}"];
	});
	NSMutableArray *out = [NSMutableArray array];
	for (NSTextCheckingResult *m in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
		NSString *link = [s substringWithRange:m.range];
		while (link.length && [trailing characterIsMember:[link characterAtIndex:link.length - 1]])
			link = [link substringToIndex:link.length - 1];
		if (link.length && ![out containsObject:link]) [out addObject:link];
	}
	return out;
}

// A short link may itself be inside a redirect wrapper, so check after cleaning.
static BOOL TLNeedsNetwork(NSString *link) {
	return TLIsShortLink([NSURL URLWithString:TLCleanLink(link)]);
}

// Maps every link in `links` to its cleaned form (possibly unchanged), then
// calls `done`: synchronously when no link needs the network, otherwise on the
// main queue once all short links are resolved.
static void TLCleanLinks(NSArray<NSString *> *links, void (^done)(NSDictionary<NSString *, NSString *> *map)) {
	NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
	dispatch_group_t group = dispatch_group_create();
	BOOL pending = NO;
	for (NSString *link in links) {
		NSString *first = link;
		NSString *unwrapped = TLCleanLink(link);
		if (TLIsShortLink([NSURL URLWithString:unwrapped])) {
			pending = YES;
			dispatch_group_enter(group);
			TLResolve(unwrapped, ^(NSString *dest) {
				dispatch_async(dispatch_get_main_queue(), ^{
					map[first] = dest ? TLCleanLink(dest) : first;
					dispatch_group_leave(group);
				});
			});
		} else {
			map[first] = unwrapped;
		}
	}
	if (!pending) { done(map); return; }
	dispatch_group_notify(group, dispatch_get_main_queue(), ^{ done(map); });
}

static BOOL TLMapChangesAnything(NSDictionary<NSString *, NSString *> *map) {
	for (NSString *link in map)
		if (![map[link] isEqualToString:link]) return YES;
	return NO;
}

static NSString *TLReplaceLinks(NSString *s, NSDictionary<NSString *, NSString *> *map) {
	// Longest first so a link that is a prefix of another isn't replaced inside it.
	NSArray *ordered = [map.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
		return a.length > b.length ? NSOrderedAscending : a.length < b.length ? NSOrderedDescending : NSOrderedSame;
	}];
	for (NSString *link in ordered)
		if (![map[link] isEqualToString:link]) s = [s stringByReplacingOccurrencesOfString:link withString:map[link]];
	return s;
}

#pragma mark - Pasteboard values

static BOOL TLIsTextType(NSString *type) {
	type = type.lowercaseString;
	return [type isEqualToString:@"public.url"] || [type hasPrefix:@"public.utf8-plain-text"] ||
	       [type isEqualToString:@"public.plain-text"] || [type isEqualToString:@"public.text"] ||
	       [type isEqualToString:@"public.utf16-plain-text"];
}

// Collects http(s) links from a value passed to a pasteboard setter: strings,
// URLs, text data, and arrays / item dictionaries of those.
static void TLCollect(id v, NSString *type, NSMutableOrderedSet<NSString *> *links) {
	if ([v isKindOfClass:[NSString class]]) {
		[links addObjectsFromArray:TLLinksInString(v)];
	} else if ([v isKindOfClass:[NSURL class]]) {
		NSString *abs = [v absoluteString];
		if (TLIsHTTP(abs)) [links addObject:abs];
	} else if ([v isKindOfClass:[NSData class]] && type && TLIsTextType(type)) {
		NSString *s = [[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding];
		if (s) [links addObjectsFromArray:TLLinksInString(s)];
	} else if ([v isKindOfClass:[NSArray class]]) {
		for (id x in v) TLCollect(x, type, links);
	} else if ([v isKindOfClass:[NSDictionary class]]) {
		[v enumerateKeysAndObjectsUsingBlock:^(id k, id x, BOOL *stop) {
			TLCollect(x, [k isKindOfClass:[NSString class]] ? k : nil, links);
		}];
	}
}

static id TLApply(id v, NSString *type, NSDictionary<NSString *, NSString *> *map) {
	if ([v isKindOfClass:[NSString class]]) return TLReplaceLinks(v, map);
	if ([v isKindOfClass:[NSURL class]]) {
		NSString *to = map[[v absoluteString]];
		return to ? ([NSURL URLWithString:to] ?: v) : v;
	}
	if ([v isKindOfClass:[NSData class]] && type && TLIsTextType(type)) {
		NSString *s = [[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding];
		return s ? [TLReplaceLinks(s, map) dataUsingEncoding:NSUTF8StringEncoding] : v;
	}
	if ([v isKindOfClass:[NSArray class]]) {
		NSMutableArray *out = [NSMutableArray arrayWithCapacity:[v count]];
		for (id x in v) [out addObject:TLApply(x, type, map)];
		return out;
	}
	if ([v isKindOfClass:[NSDictionary class]]) {
		NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:[v count]];
		[v enumerateKeysAndObjectsUsingBlock:^(id k, id x, BOOL *stop) {
			out[k] = TLApply(x, [k isKindOfClass:[NSString class]] ? k : nil, map);
		}];
		return out;
	}
	return v;
}

static BOOL TLIsGeneral(UIPasteboard *pb) {
	return [pb.name isEqualToString:UIPasteboardNameGeneral];
}

// Bumped on every write to the general pasteboard. A held write is dropped if
// a newer one happened while its short links were being resolved.
static _Atomic long gWriteGeneration = 0;
static const NSTimeInterval kTLMaxHold = 4;

// Returns a block that performs `write` at most once, and not at all if a newer
// write has started since. If nothing calls it within kTLMaxHold, `original`
// is written so the copy is never lost.
static void (^TLHeldWrite(long gen, id original, void (^write)(id)))(id) {
	__block BOOL done = NO;
	void (^finish)(id) = ^(id v) {
		if (done) return;
		done = YES;
		if (gen == gWriteGeneration) write(v);
	};
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTLMaxHold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(original); });
	return finish;
}

// Cleans the links in `value` and hands the result to `write`. Writes without
// short links go through immediately. Writes with short links are held until
// the server answers, so the pasteboard (and clipboard managers like CopyLog)
// only ever see the real link.
static void TLCleanThenWrite(UIPasteboard *pb, id value, NSString *type, void (^write)(id cleaned)) {
	if (!TLIsGeneral(pb) || !value) { write(value); return; }
	long gen = ++gWriteGeneration;

	NSMutableOrderedSet<NSString *> *links = [NSMutableOrderedSet orderedSet];
	TLCollect(value, type, links);
	if (links.count == 0) { write(value); return; }

	BOOL needsNetwork = NO;
	for (NSString *l in links) if (TLNeedsNetwork(l)) { needsNetwork = YES; break; }
	void (^finish)(id) = needsNetwork ? TLHeldWrite(gen, value, write) : write;
	TLCleanLinks(links.array, ^(NSDictionary *map) { finish(TLApply(value, type, map)); });
}

// Item providers can only be read asynchronously. Providers that carry a URL or
// plain text are loaded, cleaned and rebuilt; anything else (images, files)
// passes through untouched and immediately.
static void TLCleanProvidersThenWrite(UIPasteboard *pb, NSArray<NSItemProvider *> *providers, void (^write)(NSArray *cleaned)) {
	if (!TLIsGeneral(pb)) { write(providers); return; }
	long gen = ++gWriteGeneration;

	BOOL hasText = NO;
	for (NSItemProvider *p in providers)
		if ([p canLoadObjectOfClass:[NSURL class]] || [p canLoadObjectOfClass:[NSString class]]) { hasText = YES; break; }
	if (!hasText || providers.count > 8) { write(providers); return; }

	void (^finish)(id) = TLHeldWrite(gen, providers, write);
	NSMutableArray *urls = [NSMutableArray array], *strings = [NSMutableArray array];
	for (NSUInteger i = 0; i < providers.count; i++) { [urls addObject:[NSNull null]]; [strings addObject:[NSNull null]]; }
	dispatch_group_t group = dispatch_group_create();
	[providers enumerateObjectsUsingBlock:^(NSItemProvider *p, NSUInteger i, BOOL *stop) {
		for (Class cls in @[ [NSURL class], [NSString class] ]) {
			if (![p canLoadObjectOfClass:cls]) continue;
			NSMutableArray *slot = cls == [NSURL class] ? urls : strings;
			dispatch_group_enter(group);
			[p loadObjectOfClass:cls completionHandler:^(id obj, NSError *e) {
				dispatch_async(dispatch_get_main_queue(), ^{ if (obj) slot[i] = obj; dispatch_group_leave(group); });
			}];
		}
	}];

	dispatch_group_notify(group, dispatch_get_main_queue(), ^{
		NSMutableOrderedSet<NSString *> *links = [NSMutableOrderedSet orderedSet];
		TLCollect(urls, nil, links);
		TLCollect(strings, nil, links);
		if (links.count == 0) { finish(providers); return; }
		TLCleanLinks(links.array, ^(NSDictionary *map) {
			if (!TLMapChangesAnything(map)) { finish(providers); return; }
			NSMutableArray *out = [NSMutableArray arrayWithCapacity:providers.count];
			[providers enumerateObjectsUsingBlock:^(NSItemProvider *p, NSUInteger i, BOOL *stop) {
				id u = urls[i], s = strings[i];
				if (u == [NSNull null] && s == [NSNull null]) { [out addObject:p]; return; }
				NSItemProvider *np = [NSItemProvider new];
				if (u != [NSNull null]) [np registerObject:TLApply(u, nil, map) visibility:NSItemProviderRepresentationVisibilityAll];
				if (s != [NSNull null]) [np registerObject:TLApply(s, nil, map) visibility:NSItemProviderRepresentationVisibilityAll];
				np.suggestedName = p.suggestedName;
				[out addObject:np];
			}];
			finish(out);
		});
	});
}

#pragma mark - Fallback for unhooked write paths

static NSInteger gLastSeenChangeCount = -1;

static void TLProcess(UIPasteboard *pb) {
	NSInteger cc = pb.changeCount;
	if (cc == gLastSeenChangeCount) return;
	gLastSeenChangeCount = cc;

	if (!pb.hasURLs && !pb.hasStrings) return;
	NSURL *pbURL = pb.hasURLs ? pb.URL : nil;
	NSString *pbString = pb.hasStrings ? pb.string : nil;
	if (pbURL && !TLIsHTTP(pbURL.absoluteString)) pbURL = nil;

	NSMutableOrderedSet<NSString *> *links = [NSMutableOrderedSet orderedSet];
	TLCollect(pbString, nil, links);
	TLCollect(pbURL, nil, links);
	if (links.count == 0) return;

	TLCleanLinks(links.array, ^(NSDictionary<NSString *, NSString *> *map) {
		if (!TLMapChangesAnything(map)) return;
		if (pb.changeCount != cc) return; // user copied something else meanwhile

		NSMutableDictionary *item = [NSMutableDictionary dictionary];
		if (pbURL) item[@"public.url"] = TLApply(pbURL, nil, map);
		item[@"public.utf8-plain-text"] = pbString ? TLReplaceLinks(pbString, map) : [item[@"public.url"] absoluteString];
		[pb setItems:@[item]]; // links are clean now, so this passes straight through
	});
}

static void TLSchedule(UIPasteboard *pb) {
	if (!TLIsGeneral(pb)) return;
	// Let the write finish (and any outer hooks run) before reading it back.
	dispatch_async(dispatch_get_main_queue(), ^{ TLProcess(pb); });
}

// The general pasteboard is a _UIConcretePasteboard; hooking it covers every
// setter, including inherited ones (MSHookMessageEx adds a subclass override).
%group Hooks
%hook TLPasteboardClass
- (void)setString:(NSString *)s {
	TLCleanThenWrite(self, s, nil, ^(id v) { %orig(v); });
}
- (void)setStrings:(NSArray *)a {
	TLCleanThenWrite(self, a, nil, ^(id v) { %orig(v); });
}
- (void)setURL:(NSURL *)u {
	TLCleanThenWrite(self, u, nil, ^(id v) { %orig(v); });
}
- (void)setURLs:(NSArray *)a {
	TLCleanThenWrite(self, a, nil, ^(id v) { %orig(v); });
}
- (void)setItems:(NSArray *)a {
	TLCleanThenWrite(self, a, nil, ^(id v) { %orig(v); });
}
- (void)addItems:(NSArray *)a {
	TLCleanThenWrite(self, a, nil, ^(id v) { %orig(v); });
}
- (void)setItems:(NSArray *)a options:(NSDictionary *)o {
	TLCleanThenWrite(self, a, nil, ^(id v) { %orig(v, o); });
}
- (void)setData:(NSData *)d forPasteboardType:(NSString *)t {
	TLCleanThenWrite(self, d, t, ^(id v) { %orig(v, t); });
}
- (void)setValue:(id)val forPasteboardType:(NSString *)t {
	TLCleanThenWrite(self, val, t, ^(id v) { %orig(v, t); });
}
- (void)setObjects:(NSArray *)a {
	TLCleanThenWrite(self, a, nil, ^(id v) { %orig(v); });
}
- (void)setObjects:(NSArray *)a localOnly:(BOOL)l expirationDate:(NSDate *)e {
	TLCleanThenWrite(self, a, nil, ^(id v) { %orig(v, l, e); });
}
- (void)setItemProviders:(NSArray *)a {
	TLCleanProvidersThenWrite(self, a, ^(NSArray *v) { %orig(v); });
}
- (void)setItemProviders:(NSArray *)a localOnly:(BOOL)l expirationDate:(NSDate *)e {
	TLCleanProvidersThenWrite(self, a, ^(NSArray *v) { %orig(v, l, e); });
}
%end
%end

%ctor {
	Class cls = objc_getClass("_UIConcretePasteboard") ?: [UIPasteboard class];
	%init(Hooks, TLPasteboardClass = cls);

	// Safety net for write paths not covered above.
	[[NSNotificationCenter defaultCenter] addObserverForName:UIPasteboardChangedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		if ([note.object isKindOfClass:[UIPasteboard class]]) TLSchedule(note.object);
	}];
}
