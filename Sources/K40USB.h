#ifndef K40_USB_H
#define K40_USB_H

#include <IOKit/IOReturn.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { K40_USB_VENDOR_ID = 0x256c, K40_USB_PRODUCT_ID = 0x2002,
       K40_LABEL_PACKET_SIZE = 64 };

typedef struct {
    uint32_t locationID;
    uint16_t vendorID;
    uint16_t productID;
} K40USBDeviceInfo;

typedef struct {
    IOReturn status;
    /* kIOReturnNotReady means this phase was not attempted. */
    IOReturn transferStatus;
    IOReturn closeStatus;
    uint32_t locationID;
    uint32_t bytesRequested;
    uint32_t bytesTransferred;
} K40USBSendResult;

typedef struct {
    IOReturn status;
    uint32_t locationID;
    uint32_t descriptorLength;
    uint8_t descriptor[128];
    uint8_t hasGroupByte;
    uint8_t groupByte;
} K40USBGroupQueryResult;

/* Discovery and preflight only read registry properties; neither opens a device. */
IOReturn K40USBEnumerate(K40USBDeviceInfo *devices, size_t capacity,
                         size_t *found);
IOReturn K40USBPreflight(uint32_t locationID, K40USBDeviceInfo *device);

/* Fixed read-only indexed-string request E8. groupByte is raw descriptor[2]
   only when the response has a valid USB string-descriptor header. Its index
   base remains unknown. The raw response is always retained. */
K40USBGroupQueryResult K40USBQueryCurrentGroup(uint32_t locationID);

/* Fixed vendor discovery requests used by Huion: C9 then C8. Despite their
   GET_DESCRIPTOR shape, these may switch the device into host-control mode.
   Caller must validate the C9 identity before calling the C8 stage. */
K40USBGroupQueryResult K40USBReadControlIdentity(uint32_t locationID);
K40USBGroupQueryResult K40USBEnterControlMode(uint32_t locationID);

/* Fixed settings allowlist recovered from the vendor driver. D1/D9/DC/DE
   query battery/brightness/sleep/rotation; D7/D8/DA/DB/DD are single steps.
   Unknown command indices fail before the device is opened. */
K40USBGroupQueryResult K40USBSettingCommand(uint32_t locationID, uint8_t index);

/* locationID == 0 selects the first matching K40. Accepts only the observed
   group/key label packet shapes and sends through the verified USB path. */
K40USBSendResult K40USBSendLabelPacket(uint32_t locationID,
                                       const uint8_t packet[K40_LABEL_PACKET_SIZE]);

#ifdef __cplusplus
}
#endif

#endif
