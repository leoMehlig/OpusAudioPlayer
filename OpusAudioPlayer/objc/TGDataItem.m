#import "TGDataItem.h"

#import "ATQueue.h"

@interface TGDataItem ()
{
    ATQueue *_queue;
    NSUInteger _length;
    
    NSString *_fileName;
    bool _fileExists;
    
    NSMutableData *_data;
}

@end

@implementation TGDataItem

- (void)_commonInit
{
    _queue = [[ATQueue alloc] initWithPriority:ATQueuePriorityLow];
    _data = [[NSMutableData alloc] init];
}

- (instancetype)initWithTempFile
{
    self = [super init];
    if (self != nil)
    {
        [self _commonInit];
        
        [_queue dispatch:^
        {
            int64_t randomId = 0;
            arc4random_buf(&randomId, 8);
            self->_fileName = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSString alloc] initWithFormat:@"%" PRIx64 ".ogg", randomId]];
            self->_fileExists = false;
        }];
    }
    return self;
}

- (instancetype)initWithFilePath:(NSString *)filePath
{
    self = [super init];
    if (self != nil)
    {
        [self _commonInit];
        
        [_queue dispatch:^
        {
            self->_fileName = filePath;
            self->_length = [[[NSFileManager defaultManager] attributesOfItemAtPath:self->_fileName error:nil][NSFileSize] unsignedIntegerValue];
            self->_fileExists = [[NSFileManager defaultManager] fileExistsAtPath:self->_fileName];
        }];
    }
    return self;
}

- (void)moveToPath:(NSString *)path
{
    [_queue dispatch:^
    {   
        [[NSFileManager defaultManager] moveItemAtPath:self->_fileName toPath:path error:nil];
        self->_fileName = path;
    }];
}

- (void)remove
{
    [_queue dispatch:^
    {
        [[NSFileManager defaultManager] removeItemAtPath:self->_fileName error:nil];
    }];
}

- (void)appendData:(NSData *)data
{
    [_queue dispatch:^
    {
        if (!self->_fileExists)
        {
            [[NSFileManager defaultManager] createFileAtPath:self->_fileName contents:nil attributes:nil];
            self->_fileExists = true;
        }
        NSFileHandle *file = [NSFileHandle fileHandleForUpdatingAtPath:self->_fileName];
        [file seekToEndOfFile];
        [file writeData:data];
        [file synchronizeFile];
        [file closeFile];
        self->_length += data.length;
        
        [self->_data appendData:data];
    }];
}

- (NSData *)readDataAtOffset:(NSUInteger)offset length:(NSUInteger)length
{
    __block NSData *data = nil;
    
    [_queue dispatch:^
    {
        NSFileHandle *file = [NSFileHandle fileHandleForUpdatingAtPath:self->_fileName];
        [file seekToFileOffset:(unsigned long long)offset];
        data = [file readDataOfLength:length];
        if (data.length != length)
            NSLog(@"Read data length mismatch");
        [file closeFile];
    } synchronous:true];
    
    return data;
}

- (NSUInteger)length
{
    __block NSUInteger result = 0;
    [_queue dispatch:^
    {
        result = self->_length;
    } synchronous:true];
    
    return result;
}

- (NSString *)path {
    return _fileName;
}

@end
