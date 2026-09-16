#import <Foundation/Foundation.h>
#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>

// A small native transport observer. Never writes tokens or raw RPC messages to disk.
static pid_t childPID = 0;
static int childInput = -1;
static volatile sig_atomic_t stopping = 0;
static pthread_mutex_t stateLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableSet *accountReads, *activeThreads;
static NSString *expectedEmail, *nonce, *statePath;
static BOOL verified = NO, reliable = YES;
static const NSUInteger maxLine = 512 * 1024;

static BOOL writeAll(int fd, const void *bytes, size_t length) {
    const char *cursor = bytes;
    while (length && !stopping) {
        ssize_t n = write(fd, cursor, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        cursor += n; length -= (size_t)n;
    }
    return length == 0;
}
static void saveState(void) {
    if (!statePath) return;
    NSDictionary *state = @{
        @"nonce": nonce ?: @"", @"accountVerified": @(verified),
        @"activeTurns": @(activeThreads.count), @"trackingReliable": @(reliable),
        @"bridgePID": @(getpid()), @"childPID": @(childPID),
        @"updatedAt": @([[NSDate date] timeIntervalSince1970])
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:NULL];
    [data writeToFile:statePath options:NSDataWritingAtomic error:NULL];
    chmod(statePath.fileSystemRepresentation, 0600);
}
static void observe(NSData *line, BOOL incoming) {
    if (!line.length) return;
    id object = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
    if (![object isKindOfClass:NSDictionary.class]) return;
    NSDictionary *message = object;
    NSString *method = [message[@"method"] isKindOfClass:NSString.class] ? message[@"method"] : nil;
    pthread_mutex_lock(&stateLock);
    BOOL changed = NO;
    if (incoming) {
        if ([method isEqualToString:@"account/read"] && message[@"id"]) {
            if (accountReads.count >= 32) { reliable = NO; changed = YES; }
            else [accountReads addObject:message[@"id"]];
        }
        if ([method isEqualToString:@"account/login/start"] || [method isEqualToString:@"account/logout"]) {
            verified = NO; changed = YES;
        }
        // Reserve a thread as soon as work is requested, before turn/started can arrive.
        if ([method isEqualToString:@"turn/start"] || [method isEqualToString:@"turn/steer"]) {
            NSDictionary *params = [message[@"params"] isKindOfClass:NSDictionary.class] ? message[@"params"] : nil;
            NSString *thread = [params[@"threadId"] isKindOfClass:NSString.class] ? params[@"threadId"] : nil;
            if (thread && activeThreads.count < 128) [activeThreads addObject:thread]; else reliable = NO;
            changed = YES;
        }
    } else {
        if (message[@"id"] && [accountReads containsObject:message[@"id"]]) {
            [accountReads removeObject:message[@"id"]];
            NSDictionary *result = [message[@"result"] isKindOfClass:NSDictionary.class] ? message[@"result"] : nil;
            NSDictionary *account = [result[@"account"] isKindOfClass:NSDictionary.class] ? result[@"account"] : nil;
            NSString *email = [account[@"email"] isKindOfClass:NSString.class] ? account[@"email"] : nil;
            verified = email && [email caseInsensitiveCompare:expectedEmail] == NSOrderedSame;
            changed = YES;
        }
        if ([method isEqualToString:@"account/updated"]) { verified = NO; changed = YES; }
        NSDictionary *params = [message[@"params"] isKindOfClass:NSDictionary.class] ? message[@"params"] : nil;
        NSString *thread = [params[@"threadId"] isKindOfClass:NSString.class] ? params[@"threadId"] : nil;
        if ([method isEqualToString:@"turn/started"]) {
            if (thread && activeThreads.count < 128) [activeThreads addObject:thread]; else reliable = NO;
            changed = YES;
        } else if ([method isEqualToString:@"turn/completed"]) {
            if (thread) [activeThreads removeObject:thread]; else reliable = NO;
            changed = YES;
        } else if ([method isEqualToString:@"thread/status/changed"]) {
            NSDictionary *status = [params[@"status"] isKindOfClass:NSDictionary.class] ? params[@"status"] : nil;
            NSString *type = [status[@"type"] isKindOfClass:NSString.class] ? status[@"type"] : nil;
            if ([type isEqualToString:@"active"] && thread && activeThreads.count < 128) {
                [activeThreads addObject:thread]; changed = YES;
            } else if (([type isEqualToString:@"idle"] || [type isEqualToString:@"notLoaded"]) && thread) {
                [activeThreads removeObject:thread]; changed = YES;
            }
        }
    }
    if (changed) saveState();
    pthread_mutex_unlock(&stateLock);
}
static void relay(int source, int destination, BOOL incoming) {
    NSMutableData *line = [NSMutableData data];
    BOOL dropping = NO;
    char bytes[16384];
    while (!stopping) {
        ssize_t count = read(source, bytes, sizeof(bytes));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        @autoreleasepool {
            // Observe before forwarding, so account responses cannot overtake their requests.
            size_t offset = 0;
            while (offset < (size_t)count) {
                char *newline = memchr(bytes + offset, '\n', (size_t)count - offset);
                size_t length = newline ? (size_t)(newline - bytes) - offset : (size_t)count - offset;
                if (!dropping && line.length + length <= maxLine) [line appendBytes:bytes + offset length:length];
                else if (!dropping) {
                    // Large model/config response bodies are unrelated to task activity.
                    // Only skip an unambiguous top-level response; unknown notifications fail closed.
                    NSUInteger prefixLength = MIN(line.length, 256);
                    NSString *prefix = [[NSString alloc] initWithData:[line subdataWithRange:NSMakeRange(0, prefixLength)] encoding:NSUTF8StringEncoding];
                    NSRegularExpression *response = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\{\\s*\\\"id\\\"\\s*:\\s*(?:[0-9]+|\\\"[^\\\"]{1,128}\\\")\\s*,\\s*\\\"(?:result|error)\\\"\\s*:" options:0 error:NULL];
                    BOOL safelySkipped = !incoming && prefix && [response numberOfMatchesInString:prefix options:0 range:NSMakeRange(0, prefix.length)] > 0;
                    if (!safelySkipped) {
                        pthread_mutex_lock(&stateLock); reliable = NO; saveState(); pthread_mutex_unlock(&stateLock);
                    }
                    dropping = YES; [line setLength:0];
                }
                if (newline) {
                    if (!dropping) observe(line, incoming);
                    [line setLength:0]; dropping = NO;
                    offset += length + 1;
                } else offset += length;
            }
            if (!writeAll(destination, bytes, (size_t)count)) break;
        }
    }
}
static void *relayInput(void *unused) {
    @autoreleasepool { relay(STDIN_FILENO, childInput, YES); }
    close(childInput);
    return NULL;
}
static void stopChild(int number) {
    stopping = 1;
    if (childPID > 0) kill(childPID, SIGTERM);
}
int main(int argc, char **argv) {
    umask(0077);
    const char *real = getenv("AGENT_METER_REAL_CODEX");
    if (!real || real[0] != '/') return 64;
    BOOL server = NO;
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "app-server")) server = YES;
    if (!server) { argv[0] = (char *)real; execv(real, argv); return 127; }
    @autoreleasepool {
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        expectedEmail = [environment[@"AGENT_METER_EXPECTED_EMAIL"] copy];
        nonce = [environment[@"AGENT_METER_SESSION"] copy];
        statePath = [environment[@"AGENT_METER_STATE_PATH"] copy];
        if (!expectedEmail || !nonce || !statePath) return 64;
        accountReads = [NSMutableSet new]; activeThreads = [NSMutableSet new];
        int toChild[2], fromChild[2];
        if (pipe(toChild) || pipe(fromChild)) return 71;
        childPID = fork();
        if (childPID == 0) {
            dup2(toChild[0], STDIN_FILENO); dup2(fromChild[1], STDOUT_FILENO);
            close(toChild[0]); close(toChild[1]); close(fromChild[0]); close(fromChild[1]);
            argv[0] = (char *)real;
            execv(real, argv); _exit(127);
        }
        if (childPID < 0) return 71;
        childInput = toChild[1]; close(toChild[0]); close(fromChild[1]);
        signal(SIGPIPE, SIG_IGN);
        struct sigaction action = {0}; action.sa_handler = stopChild;
        sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL); sigaction(SIGHUP, &action, NULL);
        saveState();
        pthread_t inputThread;
        if (pthread_create(&inputThread, NULL, relayInput, NULL)) { kill(childPID, SIGTERM); return 71; }
        relay(fromChild[0], STDOUT_FILENO, NO);
        stopping = 1; close(fromChild[0]); close(childInput);
        int status = 0; BOOL reaped = NO;
        for (int i = 0; i < 100; i++) {
            pid_t result = waitpid(childPID, &status, WNOHANG);
            if (result == childPID || (result < 0 && errno == ECHILD)) { reaped = YES; break; }
            if (i == 25) kill(childPID, SIGTERM);
            usleep(20000);
        }
        if (!reaped) { kill(childPID, SIGKILL); waitpid(childPID, &status, 0); }
        pthread_mutex_lock(&stateLock); verified = NO; reliable = NO; saveState(); pthread_mutex_unlock(&stateLock);
        // The input reader may still wait on the desktop's stdin. Process exit reclaims it.
        _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 0);
    }
}
