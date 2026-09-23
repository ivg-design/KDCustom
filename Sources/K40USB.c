#include "K40USB.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>
#include <string.h>

static bool registry_number(io_service_t service, CFStringRef key, int *number) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key,
                                                       kCFAllocatorDefault, 0);
    if (!value) return false;
    bool ok = CFGetTypeID(value) == CFNumberGetTypeID() &&
              CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, number);
    CFRelease(value);
    return ok;
}

static bool device_info(io_service_t service, K40USBDeviceInfo *info) {
    int vendor = 0, product = 0, location = 0;
    if (!registry_number(service, CFSTR(kUSBVendorID), &vendor) ||
        !registry_number(service, CFSTR(kUSBProductID), &product) ||
        !registry_number(service, CFSTR(kUSBDevicePropertyLocationID), &location) ||
        vendor != K40_USB_VENDOR_ID || product != K40_USB_PRODUCT_ID)
        return false;
    info->locationID = (uint32_t)location;
    info->vendorID = (uint16_t)vendor;
    info->productID = (uint16_t)product;
    return true;
}

static IOReturn matching_iterator(io_iterator_t *iterator) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (!match) return kIOReturnNoMemory;
    int vendor = K40_USB_VENDOR_ID, product = K40_USB_PRODUCT_ID;
    CFNumberRef vendor_number = CFNumberCreate(kCFAllocatorDefault,
                                                kCFNumberIntType, &vendor);
    CFNumberRef product_number = CFNumberCreate(kCFAllocatorDefault,
                                                 kCFNumberIntType, &product);
    if (!vendor_number || !product_number) {
        if (vendor_number) CFRelease(vendor_number);
        if (product_number) CFRelease(product_number);
        CFRelease(match);
        return kIOReturnNoMemory;
    }
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), vendor_number);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), product_number);
    CFRelease(vendor_number);
    CFRelease(product_number);
    /* IOServiceGetMatchingServices consumes the matching dictionary. */
    return IOServiceGetMatchingServices(kIOMainPortDefault, match, iterator);
}

IOReturn K40USBEnumerate(K40USBDeviceInfo *devices, size_t capacity,
                         size_t *found) {
    if (!found || (capacity && !devices)) return kIOReturnBadArgument;
    *found = 0;
    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn status = matching_iterator(&iterator);
    if (status != kIOReturnSuccess) return status;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        K40USBDeviceInfo info;
        if (device_info(service, &info)) {
            if (*found < capacity) devices[*found] = info;
            ++*found;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return kIOReturnSuccess;
}

IOReturn K40USBPreflight(uint32_t locationID, K40USBDeviceInfo *device) {
    if (!device) return kIOReturnBadArgument;
    memset(device, 0, sizeof(*device));
    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn status = matching_iterator(&iterator);
    if (status != kIOReturnSuccess) return status;
    io_service_t service;
    status = kIOReturnNoDevice;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        K40USBDeviceInfo info;
        bool selected = device_info(service, &info) &&
                        (!locationID || info.locationID == locationID);
        IOObjectRelease(service);
        if (selected) {
            *device = info;
            status = kIOReturnSuccess;
            break;
        }
    }
    IOObjectRelease(iterator);
    return status;
}

static bool valid_label_packet(const uint8_t *packet) {
    if (!packet || packet[0] != 0x18 || packet[2] != 0x05 ||
        packet[3] != 0x03 || packet[4] < 1 || packet[4] > 6)
        return false;
    size_t start, length, maximum;
    if (packet[1] == 0x01) {
        start = 6;
        length = packet[5];
        maximum = 58;
    } else if (packet[1] == 0x02 && packet[5] == 0 &&
               packet[6] >= 1 && packet[6] <= 8) {
        start = 8;
        length = packet[7];
        maximum = 56;
    } else {
        return false;
    }
    if (length > maximum || (length & 1)) return false;
    for (size_t index = start + length; index < K40_LABEL_PACKET_SIZE; ++index)
        if (packet[index] != 0) return false;
    return true;
}

static IOReturn interface_for_service(io_service_t service,
                                      IOUSBDeviceInterface300 ***device) {
    *device = NULL;
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn status = IOCreatePlugInInterfaceForService(
        service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
        &plugin, &score);
    if (status != kIOReturnSuccess || !plugin) {
        if (plugin) (*plugin)->Release(plugin);
        return status != kIOReturnSuccess ? status : kIOReturnNoDevice;
    }
    HRESULT result = (*plugin)->QueryInterface(plugin,
                         CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300),
                         (LPVOID *)device);
    (*plugin)->Release(plugin);
    if (result != S_OK || !*device) {
        if (*device) (**device)->Release(*device);
        *device = NULL;
        return kIOReturnNoDevice;
    }
    return kIOReturnSuccess;
}

static K40USBGroupQueryResult query_indexed_descriptor(uint32_t locationID, uint8_t index) {
    K40USBGroupQueryResult result = { .status = kIOReturnNoDevice };
    io_iterator_t iterator = IO_OBJECT_NULL;
    result.status = matching_iterator(&iterator);
    if (result.status != kIOReturnSuccess) return result;

    io_service_t service;
    result.status = kIOReturnNoDevice;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        K40USBDeviceInfo info;
        bool selected = device_info(service, &info) &&
                        (!locationID || info.locationID == locationID);
        if (!selected) {
            IOObjectRelease(service);
            continue;
        }
        result.locationID = info.locationID;
        IOUSBDeviceInterface300 **device = NULL;
        result.status = interface_for_service(service, &device);
        IOObjectRelease(service);
        if (result.status != kIOReturnSuccess) break;

        UInt16 vendor = 0, product = 0;
        UInt32 opened_location = 0;
        result.status = (*device)->GetDeviceVendor(device, &vendor);
        if (result.status == kIOReturnSuccess)
            result.status = (*device)->GetDeviceProduct(device, &product);
        if (result.status == kIOReturnSuccess)
            result.status = (*device)->GetLocationID(device, &opened_location);
        if (result.status == kIOReturnSuccess &&
            (vendor != K40_USB_VENDOR_ID || product != K40_USB_PRODUCT_ID ||
             opened_location != info.locationID))
            result.status = kIOReturnNoDevice;

        if (result.status == kIOReturnSuccess) {
            result.status = (*device)->USBDeviceOpen(device);
            if (result.status == kIOReturnSuccess) {
                IOUSBDevRequest request = {
                    .bmRequestType = 0x80,
                    .bRequest = 0x06,
                    .wValue = (UInt16)(0x0300 | index),
                    .wIndex = 0x0409,
                    .wLength = sizeof(result.descriptor),
                    .pData = result.descriptor,
                    .wLenDone = 0
                };
                result.status = (*device)->DeviceRequest(device, &request);
                result.descriptorLength = request.wLenDone;
                if (result.descriptorLength > sizeof(result.descriptor))
                    result.descriptorLength = sizeof(result.descriptor);
                if (result.status == kIOReturnSuccess &&
                    result.descriptorLength >= 3 &&
                    result.descriptor[1] == 0x03 &&
                    result.descriptor[0] >= 3 &&
                    result.descriptor[0] <= result.descriptorLength) {
                    result.hasGroupByte = 1;
                    result.groupByte = result.descriptor[2];
                }
                IOReturn close_status = (*device)->USBDeviceClose(device);
                if (result.status == kIOReturnSuccess)
                    result.status = close_status;
            }
        }
        (*device)->Release(device);
        break;
    }
    IOObjectRelease(iterator);
    return result;
}

K40USBGroupQueryResult K40USBQueryCurrentGroup(uint32_t locationID) {
    return query_indexed_descriptor(locationID, 0xe8);
}

K40USBGroupQueryResult K40USBReadControlIdentity(uint32_t locationID) {
    return query_indexed_descriptor(locationID, 0xc9);
}

K40USBGroupQueryResult K40USBEnterControlMode(uint32_t locationID) {
    return query_indexed_descriptor(locationID, 0xc8);
}

K40USBGroupQueryResult K40USBSettingCommand(uint32_t locationID, uint8_t index) {
    switch (index) {
        case 0xd1: case 0xd7: case 0xd8: case 0xd9: case 0xda:
        case 0xdb: case 0xdc: case 0xdd: case 0xde:
            return query_indexed_descriptor(locationID, index);
        default: {
            K40USBGroupQueryResult result = {0};
            result.status = kIOReturnBadArgument;
            result.locationID = locationID;
            return result;
        }
    }
}

K40USBSendResult K40USBSendLabelPacket(uint32_t locationID,
                                       const uint8_t packet[K40_LABEL_PACKET_SIZE]) {
    K40USBSendResult result = {
        .status = kIOReturnBadArgument,
        .transferStatus = kIOReturnNotReady,
        .closeStatus = kIOReturnNotReady
    };
    if (!valid_label_packet(packet)) return result;

    io_iterator_t iterator = IO_OBJECT_NULL;
    result.status = matching_iterator(&iterator);
    if (result.status != kIOReturnSuccess) return result;

    io_service_t service;
    result.status = kIOReturnNoDevice;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        K40USBDeviceInfo info;
        bool selected = device_info(service, &info) &&
                        (!locationID || info.locationID == locationID);
        if (!selected) {
            IOObjectRelease(service);
            continue;
        }
        result.locationID = info.locationID;
        IOUSBDeviceInterface300 **device = NULL;
        result.status = interface_for_service(service, &device);
        IOObjectRelease(service);
        if (result.status != kIOReturnSuccess) break;

        UInt16 vendor = 0, product = 0;
        UInt32 opened_location = 0;
        result.status = (*device)->GetDeviceVendor(device, &vendor);
        if (result.status == kIOReturnSuccess)
            result.status = (*device)->GetDeviceProduct(device, &product);
        if (result.status == kIOReturnSuccess)
            result.status = (*device)->GetLocationID(device, &opened_location);
        if (result.status == kIOReturnSuccess &&
            (vendor != K40_USB_VENDOR_ID || product != K40_USB_PRODUCT_ID ||
             opened_location != info.locationID))
            result.status = kIOReturnNoDevice;

        if (result.status == kIOReturnSuccess) {
            result.status = (*device)->USBDeviceOpen(device);
            if (result.status == kIOReturnSuccess) {
                /* DeviceRequest takes a writable buffer and records wLenDone. */
                uint8_t payload[K40_LABEL_PACKET_SIZE];
                memcpy(payload, packet, sizeof(payload));
                IOUSBDevRequest request = {
                    .bmRequestType = 0x21,
                    .bRequest = 0x09,
                    .wValue = 0x0316,
                    .wIndex = 0x0001,
                    .wLength = K40_LABEL_PACKET_SIZE,
                    .pData = payload,
                    .wLenDone = 0
                };
                result.bytesRequested = K40_LABEL_PACKET_SIZE;
                result.transferStatus = (*device)->DeviceRequest(device, &request);
                result.status = result.transferStatus;
                result.bytesTransferred = request.wLenDone;
                result.closeStatus = (*device)->USBDeviceClose(device);
                if (result.status == kIOReturnSuccess)
                    result.status = result.closeStatus;
            }
        }
        (*device)->Release(device);
        break;
    }
    IOObjectRelease(iterator);
    return result;
}
