// Mirrors the app's microphone permission into the App Group defaults so the keyboard can decide,
// before it tries, whether in-keyboard capture may work (the hidden WKWebView records under the
// containing app's permission and cannot ask for it). Key and values are the contract in
// `SessionChannel.appMicrophonePermissionKey` (ScriberShared).
//
// Self-installing on purpose: an image constructor registers for "did finish launching" and
// "did become active" (a permission prompt, or a change in Settings, always ends with the app
// becoming active again), so no existing app file has to call it. It only reads
// AVAudioApplication.recordPermission and writes a short string; it never touches the audio
// session.

#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <UIKit/UIKit.h>

static NSString *const ScriberAppGroupID = @"group.com.geekaz.Scriber";
static NSString *const ScriberMicPermissionKey = @"app.microphonePermission";

static void ScriberPublishMicPermission(void) {
    NSString *value;
    switch ([AVAudioApplication sharedInstance].recordPermission) {
        case AVAudioApplicationRecordPermissionGranted: value = @"granted"; break;
        case AVAudioApplicationRecordPermissionDenied: value = @"denied"; break;
        default: value = @"undetermined"; break;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:ScriberAppGroupID];
    if (![[defaults stringForKey:ScriberMicPermissionKey] isEqualToString:value]) {
        [defaults setObject:value forKey:ScriberMicPermissionKey];
    }
}

__attribute__((constructor)) static void ScriberInstallMicPermissionMirror(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSNotificationName name in @[UIApplicationDidFinishLaunchingNotification,
                                      UIApplicationDidBecomeActiveNotification]) {
        [center addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) { ScriberPublishMicPermission(); }];
    }
}
