/*
 * Copyright (C) 2025 The LineageOS Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <string>
#include <vector>

#include <android-base/properties.h>
#define _REALLY_INCLUDE_SYS__SYSTEM_PROPERTIES_H_
#include <sys/_system_properties.h>

#include "vendor_init.h"

using android::base::GetProperty;
using android::base::SetProperty;

std::vector<std::string> ro_props_default_source_order = {
    "",
    "odm.",
    "system.",
    "product.",
    "system_ext.",
    "vendor.",
    "vendor_dlkm.",
};

void property_override(char const prop[], char const value[]) {
    prop_info *pi;

    pi = (prop_info *)__system_property_find(prop);
    if (pi)
        __system_property_update(pi, value, strlen(value));
    else
        __system_property_add(prop, strlen(prop), value, strlen(value));
}

void property_override_force(const char prop[], const char value[]) {
    if (SetProperty(prop, value)) return;
    // SetProperty may fail in early init; fall back to direct update
    prop_info *pi = (prop_info *)__system_property_find(prop);
    if (pi)
        __system_property_update(pi, value, strlen(value));
    else
        __system_property_add(prop, strlen(prop), value, strlen(value));
}

void set_device_props(const std::string model, const std::string marketname) {
    const auto set_ro_product_prop = [](const std::string &source,
                                        const std::string &prop,
                                        const std::string &value) {
        auto prop_name = "ro.product." + source + prop;
        property_override_force(prop_name.c_str(), value.c_str());
    };

    for (const auto &source : ro_props_default_source_order) {
        set_ro_product_prop(source, "device", model);
        set_ro_product_prop(source, "model", model);
        set_ro_product_prop(source, "name", model);
        set_ro_product_prop(source, "marketname", marketname);
    }
}

void vendor_load_properties() {
    std::string prjname = GetProperty("ro.boot.prjname", "");

    if (prjname == "20761") {
        set_device_props("RMX3191", "Realme C25");
    } else if (prjname == "20762") {
        set_device_props("RMX3193", "Realme C25");
    } else if (prjname == "2167A") {
        set_device_props("RMX3195", "Realme C25S");
    } else if (prjname == "2167C") {
        set_device_props("RMX3195", "Realme C25S");
    } else if (prjname == "2167D") {
        set_device_props("RMX3197", "Realme C25S");
    } else if (prjname == "216AF") {
        set_device_props("RMX3430", "Realme Narzo 50A");
    }
}
