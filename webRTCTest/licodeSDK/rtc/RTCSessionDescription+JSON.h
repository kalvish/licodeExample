//
//  ErizoClientIOS
//
//  Copyright (c) 2015 Alvaro Gil (zevarito@gmail.com).
//
//  MIT License, see LICENSE file for details.
//

#import "RTCSessionDescription.h"

@interface RTCSessionDescription (JSON)

+ (RTCSessionDescription *)descriptionFromJSONDictionary:(NSDictionary *)dictionary;
- (NSData *)JSONData;

@end
