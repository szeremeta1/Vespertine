//
// Vespertine: see CVespertineCacheInput.h.
// SPDX-License-Identifier: GPL-3.0-or-later
//
#import "CVespertineCacheInput.h"

// SFBInputSource keeps its designated initializer out of the public header; SFBAudioEngine is pinned to one exact version.
@interface SFBInputSource (VTDesignated)
- (instancetype)initWithURL:(nullable NSURL *)url;
- (NSError *)posixErrorWithCode:(NSInteger)code;
@end

@implementation VTCacheInputSource {
    int64_t _length;
    int64_t _offset;
    BOOL _open;
    VTCacheReadBlock _read;
}

- (instancetype)initWithURL:(NSURL *)url length:(int64_t)length read:(VTCacheReadBlock)read {
    if ((self = [super initWithURL:url])) {
        _length = length;
        _read = [read copy];
    }
    return self;
}

- (BOOL)openReturningError:(NSError **)error { _open = YES; _offset = 0; return YES; }
- (BOOL)closeReturningError:(NSError **)error { _open = NO; return YES; }
- (BOOL)isOpen { return _open; }
- (BOOL)supportsSeeking { return YES; }

- (BOOL)readBytes:(void *)buffer length:(NSInteger)length bytesRead:(NSInteger *)bytesRead error:(NSError **)error {
    NSInteger want = MIN((int64_t)length, MAX((int64_t)0, _length - _offset));
    NSInteger got = 0;
    while (got < want) {
        NSInteger n = _read(_offset + got, (char *)buffer + got, want - got);
        if (n < 0) {
            if (error) *error = [self posixErrorWithCode:EIO];
            return NO;
        }
        if (n == 0) break;
        got += n;
    }
    _offset += got;
    if (bytesRead) *bytesRead = got;
    return YES;
}

- (BOOL)getOffset:(NSInteger *)offset error:(NSError **)error { *offset = (NSInteger)_offset; return YES; }
- (BOOL)getLength:(NSInteger *)length error:(NSError **)error { *length = (NSInteger)_length; return YES; }

- (BOOL)seekToOffset:(NSInteger)offset error:(NSError **)error {
    if (offset < 0 || offset > _length) {
        if (error) *error = [self posixErrorWithCode:EINVAL];
        return NO;
    }
    _offset = offset;
    return YES;
}

@end
