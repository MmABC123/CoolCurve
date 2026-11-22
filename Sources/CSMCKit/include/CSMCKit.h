#ifndef CSMCKIT_H
#define CSMCKIT_H

#include <stdint.h>
#include <stdbool.h>
#include <IOKit/IOKitLib.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KERNEL_INDEX_SMC 2

#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_WRITE_BYTES   6
#define SMC_CMD_READ_INDEX    8
#define SMC_CMD_READ_KEYINFO  9

typedef struct {
    char     major;
    char     minor;
    char     build;
    char     reserved[1];
    uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char     dataAttributes;
} SMCKeyData_keyInfo_t;

typedef uint8_t SMCBytes_t[32];

typedef struct {
    uint32_t                key;
    SMCKeyData_vers_t       vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t    keyInfo;
    char                    result;
    char                    status;
    char                    data8;
    uint32_t                data32;
    SMCBytes_t              bytes;
} SMCKeyData_t;

/// Opens a connection to the AppleSMC driver.
kern_return_t csmc_open(io_connect_t *outConn);

/// Closes an open AppleSMC connection.
kern_return_t csmc_close(io_connect_t conn);

/// Converts a 4-character string (e.g. "F0Ac") into a 32-bit fourcc integer.
uint32_t csmc_str_to_fourcc(const char *str);

/// Reads raw bytes and key info for a 4-character SMC key.
kern_return_t csmc_read_key(
    io_connect_t conn,
    const char *keyStr,
    uint32_t *outDataType,
    uint32_t *outDataSize,
    uint8_t outBytes[32]
);

/// Writes raw bytes to a 4-character SMC key. Requires root privileges for protected keys.
kern_return_t csmc_write_key(
    io_connect_t conn,
    const char *keyStr,
    uint32_t dataType,
    uint32_t dataSize,
    const uint8_t *inBytes
);

/// Reads only the value bytes of a key whose size is already known (one SMC call instead of two).
kern_return_t csmc_read_bytes(io_connect_t conn, const char *keyStr, uint32_t dataSize, uint8_t outBytes[32]);

/// Decodes raw SMC bytes of type ui8, ui16, ui32, si8, si16, flt, sp78, fpe2, hex_ into a double.
bool csmc_decode_double(uint32_t dataType, uint32_t dataSize, const uint8_t bytes[32], double *outValue);

/// Reads a numeric SMC key and decodes ui8, ui16, ui32, si16, flt, sp78, fpe2 into a double.
bool csmc_read_double(io_connect_t conn, const char *keyStr, double *outValue);

/// Writes a numeric value to an SMC key, matching its native dataType (ui8, ui16, flt, fpe2).
bool csmc_write_double(io_connect_t conn, const char *keyStr, double value);

/// Reads Apple Silicon / macOS thermal sensors via IOHIDEventSystemClient as a fallback or primary thermal source.
/// Returns the number of valid temperature sensors read, and populates average and max temperatures in Celsius.
int csmc_read_hid_temperatures(double *outAvgCelsius, double *outMaxCelsius);

/// Elevates effective UID/GID to 0 when running as a setuid root helper binary.
int csmc_elevate_root(void);

#ifdef __cplusplus
}
#endif

#endif /* CSMCKIT_H */
