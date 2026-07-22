#import <CoreFoundation/CoreFoundation.h>

void nimculus_test_pump_main_run_loop(double seconds) {
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, true);
}
