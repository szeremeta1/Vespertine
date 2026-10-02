//
// Vespertine — TagLib's property map, for what SFBAudioEngine's metadata writer can't carry.
// SPDX-License-Identifier: GPL-3.0-or-later
//

#include "CVespertineTags.h"

#include <taglib/fileref.h>
#include <taglib/tpropertymap.h>
#include <taglib/tstringlist.h>

#include <cstring>
#include <new>
#include <set>
#include <string>

struct NVTMultiValued {
    TagLib::PropertyMap fields;
};

namespace {

TagLib::String utf8(const char *s) { return TagLib::String(s, TagLib::String::UTF8); }

} // namespace

NVTMultiValued *nvt_multivalued_read(const char *path) {
    TagLib::FileRef file(path, false);
    if (file.isNull()) return nullptr;
    auto *set = new (std::nothrow) NVTMultiValued();
    if (!set) return nullptr;
    for (const auto &[key, values] : file.properties())
        if (values.size() > 1) set->fields.replace(key, values);
    return set;
}

int nvt_multivalued_count(const NVTMultiValued *set) { return static_cast<int>(set->fields.size()); }

int nvt_multivalued_restore(const NVTMultiValued *set, const char *path, const char *const *skip, int skipCount) {
    if (set->fields.isEmpty()) return 0;
    std::set<TagLib::String> skipped;
    for (int i = 0; skip && i < skipCount; i++) skipped.insert(utf8(skip[i]).upper());
    TagLib::FileRef file(path, false);
    if (file.isNull()) return -1;
    TagLib::PropertyMap now = file.properties();
    TagLib::PropertyMap restore;
    for (const auto &[key, values] : set->fields) {
        if (skipped.count(key.upper())) continue;
        // Only a field the save cut down to its first value (or dropped): anything else was changed on purpose.
        auto it = now.find(key);
        if (it != now.end() && !(it->second.size() == 1 && it->second.front() == values.front())) continue;
        now.replace(key, values);
        restore.replace(key, values);
    }
    if (restore.isEmpty()) return 0;
    const TagLib::PropertyMap refused = file.setProperties(now);
    if (!file.save()) return -1;
    int restored = 0;
    for (const auto &entry : restore)
        if (!refused.contains(entry.first)) restored++;
    return restored;
}

void nvt_multivalued_free(NVTMultiValued *set) { delete set; }

int nvt_property_set(const char *path, const char *key, const char *const *values, int count) {
    TagLib::FileRef file(path, false);
    if (file.isNull()) return -1;
    TagLib::PropertyMap map = file.properties();
    TagLib::StringList list;
    for (int i = 0; values && i < count; i++) list.append(utf8(values[i]));
    if (list.isEmpty()) map.erase(utf8(key));
    else map.replace(utf8(key), list);
    file.setProperties(map);
    return file.save() ? 0 : -1;
}

int nvt_property_get(const char *path, const char *key, char *buffer, int size) {
    if (size > 0) buffer[0] = 0;
    TagLib::FileRef file(path, false);
    if (file.isNull()) return -1;
    const TagLib::PropertyMap map = file.properties();
    auto it = map.find(utf8(key));
    if (it == map.end()) return 0;
    const std::string joined = it->second.toString("\n").to8Bit(true);
    if (size > 0) {
        const size_t n = joined.size() < static_cast<size_t>(size - 1) ? joined.size() : static_cast<size_t>(size - 1);
        std::memcpy(buffer, joined.data(), n);
        buffer[n] = 0;
    }
    return static_cast<int>(it->second.size());
}
