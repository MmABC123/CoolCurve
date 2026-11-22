#include "CSMCKit.h"
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <math.h>

uint32_t csmc_str_to_fourcc(const char *str) {
    if (!str) return 0;
    uint32_t val = 0;
    for (int i = 0; i < 4; i++) {
        uint8_t ch = (str[i] != '\0') ? (uint8_t)str[i] : ' ';
        val = (val << 8) | ch;
    }
    return val;
}

kern_return_t csmc_open(io_connect_t *outConn) {
    if (!outConn) return kIOReturnBadArgument;
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSMC")
    );
    if (!service) {
        return kIOReturnNotFound;
    }
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, outConn);
    IOObjectRelease(service);
    return result;
}

kern_return_t csmc_close(io_connect_t conn) {
    if (!conn) return kIOReturnSuccess;
    return IOServiceClose(conn);
}

static kern_return_t csmc_call(
    io_connect_t conn,
    const SMCKeyData_t *inputStruct,
    SMCKeyData_t *outputStruct
) {
    size_t inputSize = sizeof(SMCKeyData_t);
    size_t outputSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(
        conn,
        KERNEL_INDEX_SMC,
        inputStruct,
        inputSize,
        outputStruct,
        &outputSize
    );
}

kern_return_t csmc_read_key(
    io_connect_t conn,
    const char *keyStr,
    uint32_t *outDataType,
    uint32_t *outDataSize,
    uint8_t outBytes[32]
) {
    if (!conn || !keyStr) return kIOReturnBadArgument;

    SMCKeyData_t inputStruct;
    SMCKeyData_t outputStruct;
    memset(&inputStruct, 0, sizeof(SMCKeyData_t));
    memset(&outputStruct, 0, sizeof(SMCKeyData_t));

    inputStruct.key = csmc_str_to_fourcc(keyStr);
    inputStruct.data8 = SMC_CMD_READ_KEYINFO;

    kern_return_t kr = csmc_call(conn, &inputStruct, &outputStruct);
    if (kr != kIOReturnSuccess || outputStruct.result != 0) {
        return (kr != kIOReturnSuccess) ? kr : kIOReturnError;
    }

    uint32_t dataSize = outputStruct.keyInfo.dataSize;
    uint32_t dataType = outputStruct.keyInfo.dataType;

    if (outDataType) *outDataType = dataType;
    if (outDataSize) *outDataSize = dataSize;

    if (!outBytes) {
        return kIOReturnSuccess;
    }

    memset(&inputStruct, 0, sizeof(SMCKeyData_t));
    inputStruct.key = csmc_str_to_fourcc(keyStr);
    inputStruct.keyInfo.dataSize = dataSize;
    inputStruct.data8 = SMC_CMD_READ_BYTES;

    memset(&outputStruct, 0, sizeof(SMCKeyData_t));
    kr = csmc_call(conn, &inputStruct, &outputStruct);
    if (kr != kIOReturnSuccess || outputStruct.result != 0) {
        return (kr != kIOReturnSuccess) ? kr : kIOReturnError;
    }

    uint32_t copyLen = (dataSize <= 32) ? dataSize : 32;
    memcpy(outBytes, outputStruct.bytes, copyLen);
    return kIOReturnSuccess;
}

kern_return_t csmc_write_key(
    io_connect_t conn,
    const char *keyStr,
    uint32_t dataType,
    uint32_t dataSize,
    const uint8_t *inBytes
) {
    if (!conn || !keyStr || !inBytes || dataSize == 0 || dataSize > 32) {
        return kIOReturnBadArgument;
    }

    SMCKeyData_t inputStruct;
    SMCKeyData_t outputStruct;
    memset(&inputStruct, 0, sizeof(SMCKeyData_t));
    memset(&outputStruct, 0, sizeof(SMCKeyData_t));

    inputStruct.key = csmc_str_to_fourcc(keyStr);
    inputStruct.data8 = SMC_CMD_WRITE_BYTES;
    inputStruct.keyInfo.dataSize = dataSize;
    inputStruct.keyInfo.dataType = dataType;
    memcpy(inputStruct.bytes, inBytes, dataSize);

    kern_return_t kr = csmc_call(conn, &inputStruct, &outputStruct);
    if (kr != kIOReturnSuccess || outputStruct.result != 0) {
        return (kr != kIOReturnSuccess) ? kr : kIOReturnNotPrivileged;
    }
    return kIOReturnSuccess;
}

kern_return_t csmc_read_bytes(io_connect_t conn, const char *keyStr, uint32_t dataSize, uint8_t outBytes[32]) {
    if (!conn || !keyStr || !outBytes) return kIOReturnBadArgument;

    SMCKeyData_t inputStruct;
    SMCKeyData_t outputStruct;
    memset(&inputStruct, 0, sizeof(SMCKeyData_t));
    memset(&outputStruct, 0, sizeof(SMCKeyData_t));
    inputStruct.key = csmc_str_to_fourcc(keyStr);
    inputStruct.keyInfo.dataSize = dataSize;
    inputStruct.data8 = SMC_CMD_READ_BYTES;

    kern_return_t kr = csmc_call(conn, &inputStruct, &outputStruct);
    if (kr != kIOReturnSuccess || outputStruct.result != 0) {
        return (kr != kIOReturnSuccess) ? kr : kIOReturnError;
    }
    memcpy(outBytes, outputStruct.bytes, (dataSize <= 32) ? dataSize : 32);
    return kIOReturnSuccess;
}

bool csmc_read_double(io_connect_t conn, const char *keyStr, double *outValue) {
    uint32_t dataType = 0;
    uint32_t dataSize = 0;
    uint8_t bytes[32] = {0};
    if (csmc_read_key(conn, keyStr, &dataType, &dataSize, bytes) != kIOReturnSuccess) {
        return false;
    }
    return csmc_decode_double(dataType, dataSize, bytes, outValue);
}

bool csmc_decode_double(uint32_t dataType, uint32_t dataSize, const uint8_t bytes[32], double *outValue) {
    if (!outValue) return false;

    uint32_t typeFlt  = csmc_str_to_fourcc("flt ");
    uint32_t typeFpe2 = csmc_str_to_fourcc("fpe2");
    uint32_t typeSp78 = csmc_str_to_fourcc("sp78");
    uint32_t typeUi8  = csmc_str_to_fourcc("ui8 ");
    uint32_t typeUi16 = csmc_str_to_fourcc("ui16");
    uint32_t typeUi32 = csmc_str_to_fourcc("ui32");
    uint32_t typeSi8  = csmc_str_to_fourcc("si8 ");
    uint32_t typeSi16 = csmc_str_to_fourcc("si16");
    uint32_t typeHex  = csmc_str_to_fourcc("hex_");

    if (dataType == typeFlt && dataSize == 4) {
        float f = 0.0f;
        memcpy(&f, bytes, 4);
        if (!isfinite(f)) return false;
        *outValue = (double)f;
        return true;
    } else if (dataType == typeFpe2 && dataSize == 2) {
        uint16_t raw = ((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1];
        *outValue = (double)raw / 4.0;
        return true;
    } else if (dataType == typeSp78 && dataSize == 2) {
        int16_t raw = (int16_t)(((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1]);
        *outValue = (double)raw / 256.0;
        return true;
    } else if ((dataType == typeUi8 || dataType == typeHex) && dataSize == 1) {
        *outValue = (double)bytes[0];
        return true;
    } else if (dataType == typeSi8 && dataSize == 1) {
        *outValue = (double)((int8_t)bytes[0]);
        return true;
    } else if (dataType == typeUi16 && dataSize == 2) {
        uint16_t raw = ((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1];
        *outValue = (double)raw;
        return true;
    } else if (dataType == typeSi16 && dataSize == 2) {
        int16_t raw = (int16_t)(((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1]);
        *outValue = (double)raw;
        return true;
    } else if (dataType == typeUi32 && dataSize == 4) {
        uint32_t raw = ((uint32_t)bytes[0] << 24) |
                       ((uint32_t)bytes[1] << 16) |
                       ((uint32_t)bytes[2] << 8)  |
                       (uint32_t)bytes[3];
        *outValue = (double)raw;
        return true;
    }
    return false;
}

bool csmc_write_double(io_connect_t conn, const char *keyStr, double value) {
    uint32_t dataType = 0;
    uint32_t dataSize = 0;
    if (csmc_read_key(conn, keyStr, &dataType, &dataSize, NULL) != kIOReturnSuccess) {
        return false;
    }

    uint32_t typeFlt  = csmc_str_to_fourcc("flt ");
    uint32_t typeFpe2 = csmc_str_to_fourcc("fpe2");
    uint32_t typeUi8  = csmc_str_to_fourcc("ui8 ");
    uint32_t typeUi16 = csmc_str_to_fourcc("ui16");
    uint32_t typeHex  = csmc_str_to_fourcc("hex_");

    uint8_t bytes[32] = {0};

    if (dataType == typeFlt && dataSize == 4) {
        float f = (float)value;
        memcpy(bytes, &f, 4);
    } else if (dataType == typeFpe2 && dataSize == 2) {
        uint16_t raw = (uint16_t)(value * 4.0);
        bytes[0] = (uint8_t)((raw >> 8) & 0xFF);
        bytes[1] = (uint8_t)(raw & 0xFF);
    } else if ((dataType == typeUi8 || dataType == typeHex) && dataSize == 1) {
        bytes[0] = (uint8_t)value;
    } else if (dataType == typeUi16 && dataSize == 2) {
        uint16_t raw = (uint16_t)value;
        bytes[0] = (uint8_t)((raw >> 8) & 0xFF);
        bytes[1] = (uint8_t)(raw & 0xFF);
    } else {
        return false;
    }

    return csmc_write_key(conn, keyStr, dataType, dataSize, bytes) == kIOReturnSuccess;
}

// Apple Silicon HID temperature sensor support via dynamic symbol lookup
typedef CFTypeRef (*IOHIDEventSystemClientCreate_f)(CFAllocatorRef allocator);
typedef int (*IOHIDEventSystemClientSetMatching_f)(CFTypeRef client, CFDictionaryRef match);
typedef CFArrayRef (*IOHIDEventSystemClientCopyServices_f)(CFTypeRef client);
typedef CFTypeRef (*IOHIDServiceClientCopyEvent_f)(CFTypeRef service, int64_t type, int32_t options, int64_t timeout);
typedef double (*IOHIDEventGetFloatValue_f)(CFTypeRef event, int32_t field);

int csmc_read_hid_temperatures(double *outAvgCelsius, double *outMaxCelsius) {
    if (outAvgCelsius) *outAvgCelsius = 0.0;
    if (outMaxCelsius) *outMaxCelsius = 0.0;

    static void *iokitHandle = NULL;
    static IOHIDEventSystemClientCreate_f fnCreate = NULL;
    static IOHIDEventSystemClientSetMatching_f fnSetMatching = NULL;
    static IOHIDEventSystemClientCopyServices_f fnCopyServices = NULL;
    static IOHIDServiceClientCopyEvent_f fnCopyEvent = NULL;
    static IOHIDEventGetFloatValue_f fnGetFloat = NULL;

    if (!iokitHandle) {
        iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (iokitHandle) {
            fnCreate = (IOHIDEventSystemClientCreate_f)dlsym(iokitHandle, "IOHIDEventSystemClientCreate");
            fnSetMatching = (IOHIDEventSystemClientSetMatching_f)dlsym(iokitHandle, "IOHIDEventSystemClientSetMatching");
            fnCopyServices = (IOHIDEventSystemClientCopyServices_f)dlsym(iokitHandle, "IOHIDEventSystemClientCopyServices");
            fnCopyEvent = (IOHIDServiceClientCopyEvent_f)dlsym(iokitHandle, "IOHIDServiceClientCopyEvent");
            fnGetFloat = (IOHIDEventGetFloatValue_f)dlsym(iokitHandle, "IOHIDEventGetFloatValue");
        }
    }

    if (!fnCreate || !fnSetMatching || !fnCopyServices || !fnCopyEvent || !fnGetFloat) {
        return 0;
    }

    CFTypeRef client = fnCreate(kCFAllocatorDefault);
    if (!client) return 0;

    int pageVal = 0xFF00; // kHIDPage_AppleVendor
    int usageVal = 5;     // kHIDUsage_AppleVendor_TemperatureSensor
    CFNumberRef pageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pageVal);
    CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usageVal);

    const void *keys[2] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[2] = { pageNum, usageNum };
    CFDictionaryRef matchDict = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        vals,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );

    fnSetMatching(client, matchDict);
    CFRelease(matchDict);
    CFRelease(pageNum);
    CFRelease(usageNum);

    CFArrayRef services = fnCopyServices(client);
    if (!services) {
        CFRelease(client);
        return 0;
    }

    CFIndex count = CFArrayGetCount(services);
    double sum = 0.0;
    double maxTemp = 0.0;
    int validCount = 0;

    // kIOHIDEventTypeTemperature = 15, field = (15 << 16)
    const int64_t kEventTypeTemp = 15;
    const int32_t kFieldTempLevel = (15 << 16);

    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef service = CFArrayGetValueAtIndex(services, i);
        if (!service) continue;
        CFTypeRef event = fnCopyEvent(service, kEventTypeTemp, 0, 0);
        if (!event) continue;
        double temp = fnGetFloat(event, kFieldTempLevel);
        CFRelease(event);

        if (temp > 15.0 && temp < 125.0) {
            sum += temp;
            if (temp > maxTemp) {
                maxTemp = temp;
            }
            validCount++;
        }
    }

    CFRelease(services);
    CFRelease(client);

    if (validCount > 0) {
        if (outAvgCelsius) *outAvgCelsius = sum / (double)validCount;
        if (outMaxCelsius) *outMaxCelsius = maxTemp;
    }
    return validCount;
}

int csmc_elevate_root(void) {
    setuid(0);
    seteuid(0);
    setgid(0);
    setegid(0);
    return (geteuid() == 0) ? 0 : -1;
}
