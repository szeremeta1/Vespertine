//
// Vespertine — TagLib's property map, for what SFBAudioEngine's metadata writer can't carry: it writes one value
// per field, so a save would keep only the first of several artists, genres or MusicBrainz IDs.
// SPDX-License-Identifier: GPL-3.0-or-later
//
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The fields of a file's tags that hold more than one value, by their TagLib property names.
typedef struct NVTMultiValued NVTMultiValued;

/// Reads the multi-valued fields of the file at `path`. NULL if TagLib can't read it; otherwise a set (maybe empty).
NVTMultiValued *_Nullable nvt_multivalued_read(const char *_Nonnull path);
/// How many fields the set holds.
int nvt_multivalued_count(const NVTMultiValued *_Nonnull set);
/// Puts back every field of `set` that the file now holds with only its first value, or not at all, except the
/// `skipCount` property names in `skip` (fields that were edited on purpose). Returns how many fields it
/// restored, or -1 if the file couldn't be read or saved.
int nvt_multivalued_restore(const NVTMultiValued *_Nonnull set, const char *_Nonnull path,
                            const char *_Nonnull const *_Nullable skip, int skipCount);
void nvt_multivalued_free(NVTMultiValued *_Nullable set);

/// Replaces the property `key` with `count` values; no values removes it. 0 on success, -1 on failure.
int nvt_property_set(const char *_Nonnull path, const char *_Nonnull key,
                     const char *_Nonnull const *_Nullable values, int count);
/// The values of the property `key`, one per line, into `buffer` (cut at `size` bytes, NUL-terminated).
/// Returns how many values it has (0 if none), or -1 if the file couldn't be read.
int nvt_property_get(const char *_Nonnull path, const char *_Nonnull key, char *_Nonnull buffer, int size);

#ifdef __cplusplus
}
#endif
