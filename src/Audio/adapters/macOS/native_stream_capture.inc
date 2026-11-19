// Compiled into the existing Core Audio capture binding for the native trial.
#import "../Apple/GStreamerStreamHost.h"
#include <chrono>
#include <thread>
static BAGStreamerStreamHost *nativeStreams;
static std::atomic<uint64_t> captureOwnerContact{0},captureStopAt{0};
static std::atomic<bool> captureStopRequested{false};
static uint64_t nativeNowMS() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
static void packet(uint8_t type,const void *data,uint32_t bytes) {
    if(type==1) { [nativeStreams captureFormat:data size:bytes];wirePacket(type,data,bytes);fflush(stdout); }
    else if(type==2) [nativeStreams captureBlock:data size:bytes];
    else if(type==3 || type==6) { wirePacket(type,data,bytes);fflush(stdout); }
    // Capture buffers and per-block callback timings never cross stdout.
}
static void nativeStart() {
    nativeStreams=[BAGStreamerStreamHost new];NSError *error=nil;
    uint16_t port=[nativeStreams start:&error];if(!port)throw Failure{-1,"Start native stream service"};
    uint16_t networkPort=htons(port);wirePacket(9,&networkPort,2);fflush(stdout);
    captureOwnerContact=nativeNowMS();
    std::thread([] {
        uint8_t command[5];
        while(fread(command,1,5,stdin)==5){
            if(!memcmp(command,"\0\0\0\1h",5))captureOwnerContact=nativeNowMS();
            else if(!memcmp(command,"\0\0\0\1s",5)){
                captureStopAt=nativeNowMS();captureStopRequested=true;return;
            } else _Exit(65);
        }
        _Exit(70);
    }).detach();
    std::thread([] {
        for(;;) {
            pollfd owner={STDIN_FILENO,POLLIN,0};
            bool lost=poll(&owner,1,0)>0 && (owner.revents&(POLLHUP|POLLERR|POLLNVAL));
            // Process exit is the hard boundary: no media descendants exist.
            if(lost || nativeNowMS()-captureOwnerContact.load()>2000 ||
                (captureStopRequested && nativeNowMS()-captureStopAt.load()>1500))_Exit(70);
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
    }).detach();
}
