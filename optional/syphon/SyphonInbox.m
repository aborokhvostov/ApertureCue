// ApertureCue optional helper. GPL-3.0-or-later. See the repository LICENSE.
#define GL_SILENCE_DEPRECATION
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <Syphon/SyphonMetalClient.h>
#import <Syphon/SyphonOpenGLServer.h>
#import <Syphon/SyphonServerDirectory.h>
#import <libkern/OSByteOrder.h>
#import <signal.h>
#import <sys/stat.h>
#import <unistd.h>

static volatile sig_atomic_t shouldStop;
static void stop(int signalNumber) { (void)signalNumber; shouldStop = 1; }

static void step(NSTimeInterval seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static BOOL isFeedName(NSString *name) {
    NSData *bytes = [name dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:NO];
    if (bytes.length == 0 || bytes.length > 48) return NO;
    const unsigned char *s = bytes.bytes;
    for (NSUInteger i = 0; i < bytes.length; ++i) {
        const unsigned char c = s[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '-' || c == '_')) return NO;
    }
    return YES;
}

static NSURL *inbox(NSString *path) {
    NSURL *candidate = [[[NSURL fileURLWithPath:path isDirectory:YES] URLByStandardizingPath] URLByResolvingSymlinksInPath];
    NSURL *parent = [[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByStandardizingPath] URLByResolvingSymlinksInPath];
    if (![[candidate URLByDeletingLastPathComponent].path isEqualToString:parent.path] ||
        ![candidate.lastPathComponent hasPrefix:@"ApertureCue-video-"]) return nil;
    struct stat attributes;
    if (lstat(candidate.fileSystemRepresentation, &attributes) != 0 || !S_ISDIR(attributes.st_mode) ||
        (attributes.st_mode & 0777) != 0700 || attributes.st_uid != getuid()) return nil;
    return [NSFileManager.defaultManager fileExistsAtPath:
        [[candidate URLByAppendingPathComponent:@".aperturecue-video-v1"] path]] ? candidate : nil;
}

static int listSources(void) {
    SyphonServerDirectory *directory = SyphonServerDirectory.sharedDirectory;
    step(0.75);
    for (NSDictionary *source in directory.servers) {
        NSString *application = source[SyphonServerDescriptionAppNameKey] ?: @"Unknown application";
        NSString *name = source[SyphonServerDescriptionNameKey] ?: @"";
        printf("%s\t%s\n", application.UTF8String, name.UTF8String);
    }
    return 0;
}

static BOOL publishFrame(id<MTLTexture> texture, id<MTLCommandQueue> queue,
                         NSURL *destination, NSUUID *producer, uint64_t sequence) {
    if (!texture || texture.width == 0 || texture.height == 0 ||
        texture.width > 1280 || texture.height > 720 ||
        (texture.pixelFormat != MTLPixelFormatBGRA8Unorm && texture.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB)) return NO;
    NSUInteger tight = texture.width * 4;
    NSUInteger stride = (tight + 255) & ~(NSUInteger)255;
    NSUInteger length = stride * texture.height;
    id<MTLBuffer> buffer = [queue.device newBufferWithLength:length options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = queue.commandBuffer;
    id<MTLBlitCommandEncoder> copy = command.blitCommandEncoder;
    if (!buffer || !command || !copy) return NO;
    [copy copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(texture.width, texture.height, 1) toBuffer:buffer
        destinationOffset:0 destinationBytesPerRow:stride destinationBytesPerImage:length];
    [copy endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) return NO;

    NSMutableData *record = [NSMutableData dataWithCapacity:40 + tight * texture.height];
    [record appendBytes:"ACFRAME1" length:8];
    uuid_t identifier;
    [producer getUUIDBytes:identifier];
    [record appendBytes:identifier length:sizeof(identifier)];
    uint64_t sequenceBE = OSSwapHostToBigInt64(sequence);
    uint32_t widthBE = OSSwapHostToBigInt32((uint32_t)texture.width);
    uint32_t heightBE = OSSwapHostToBigInt32((uint32_t)texture.height);
    [record appendBytes:&sequenceBE length:sizeof(sequenceBE)];
    [record appendBytes:&widthBE length:sizeof(widthBE)];
    [record appendBytes:&heightBE length:sizeof(heightBE)];
    const uint8_t *bytes = buffer.contents;
    for (NSUInteger y = 0; y < texture.height; ++y) {
        [record appendBytes:bytes + y * stride length:tight];
    }
    return [record writeToURL:destination options:NSDataWritingAtomic error:NULL];
}

static int receive(NSString *path, NSString *feed, NSString *name, NSString *app) {
    NSURL *root = inbox(path);
    if (!root || !isFeedName(feed) || name.length == 0) { fputs("Choose a private active inbox and a valid feed name.\n", stderr); return 2; }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) { fputs("Metal unavailable.\n", stderr); return 2; }

    NSURL *target = [root URLByAppendingPathComponent:[feed stringByAppendingString:@".acframe"]];
    SyphonMetalClient *client = nil;
    NSUUID *identifier = [NSUUID UUID];
    uint64_t sequence = 0;
    NSTimeInterval nextLookup = 0;
    BOOL hadFrame = NO;
    while (!shouldStop && [NSFileManager.defaultManager fileExistsAtPath:root.path]) {
        @autoreleasepool {
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            if (!client.isValid && now >= nextLookup) {
                [client stop];
                client = nil;
                NSArray *choices = [SyphonServerDirectory.sharedDirectory serversMatchingName:name
                                                                                      appName:app.length > 0 ? app : nil];
                if (choices.count == 1) {
                    client = [[SyphonMetalClient alloc] initWithServerDescription:choices.firstObject device:device
                                                                         options:nil newFrameHandler:nil];
                } else if (choices.count > 1) {
                    fputs("More than one matching Syphon source. Supply a unique name and application.\n", stderr);
                    return 2;
                }
                nextLookup = now + 0.35;
            }
            if (client.isValid && client.hasNewFrame) {
                id<MTLTexture> texture = [client newFrameImage];
                if (publishFrame(texture, queue, target, identifier, ++sequence)) {
                    if (!hadFrame) { printf("Receiving %s\n", name.UTF8String); fflush(stdout); hadFrame = YES; }
                } else if (hadFrame) {
                    fputs("Frame could not be published. Check texture size, pixel format and inbox.\n", stderr);
                    hadFrame = NO;
                }
            }
            step(1.0 / 24.0);
        }
    }
    [client stop];
    return 0;
}

/// An original 96×64 pattern for independent-process interoperability checks.
static int originalFixture(NSString *name) {
    const CGLPixelFormatAttribute attributes[] = { kCGLPFAColorSize, 24, kCGLPFAAlphaSize, 8, 0 };
    CGLPixelFormatObj format = NULL;
    GLint count = 0;
    if (CGLChoosePixelFormat(attributes, &format, &count) != kCGLNoError || !format) return 2;
    CGLContextObj context = NULL;
    CGLError created = CGLCreateContext(format, NULL, &context);
    CGLDestroyPixelFormat(format);
    if (created != kCGLNoError || !context) return 2;
    CGLSetCurrentContext(context);
    SyphonOpenGLServer *server = [[SyphonOpenGLServer alloc] initWithName:name context:context options:nil];
    if (!server) { CGLSetCurrentContext(NULL); CGLDestroyContext(context); return 2; }
    const int width = 96, height = 64;
    GLubyte pixels[96 * 64 * 4];
    for (int i = 0; i < width * height; ++i) {
        pixels[i * 4] = 23; pixels[i * 4 + 1] = 92; pixels[i * 4 + 2] = 221; pixels[i * 4 + 3] = 255;
    }
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, texture);
    glTexImage2D(GL_TEXTURE_RECTANGLE_ARB, 0, GL_RGBA8, width, height, 0, GL_BGRA, GL_UNSIGNED_BYTE, pixels);
    while (!shouldStop) {
        @autoreleasepool {
            [server publishFrameTexture:texture textureTarget:GL_TEXTURE_RECTANGLE_ARB imageRegion:NSMakeRect(0, 0, width, height)
                      textureDimensions:NSMakeSize(width, height) flipped:NO];
            step(1.0 / 20.0);
        }
    }
    [server stop];
    glDeleteTextures(1, &texture);
    CGLSetCurrentContext(NULL);
    CGLDestroyContext(context);
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        signal(SIGTERM, stop);
        signal(SIGINT, stop);
        if (argc == 2 && strcmp(argv[1], "list") == 0) return listSources();
        if (argc == 3 && strcmp(argv[1], "original-fixture") == 0) {
            return originalFixture([NSString stringWithUTF8String:argv[2]]);
        }
        if ((argc == 5 || argc == 6) && strcmp(argv[1], "receive") == 0) {
            return receive([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]],
                           [NSString stringWithUTF8String:argv[4]], argc == 6 ? [NSString stringWithUTF8String:argv[5]] : nil);
        }
        fputs("Usage: aperturecue-syphon list | receive INBOX FEED SERVER [APPLICATION] | original-fixture SERVER\n", stderr);
        return 2;
    }
}
