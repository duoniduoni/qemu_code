// Copyright (C) 2016 The Android Open Source Project
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#pragma once

#include "android/base/StringView.h"
#include "android/skin/rect.h"

#include <functional>

namespace emugl {
    class Renderer;
}

namespace android {
namespace emulation {

bool captureScreenshot(android::base::StringView outputDirectoryPath,
                       std::string* outputFilepath = NULL);
// The following one is for testing only
// It loads texture from renderer if renderer is not null.
// (-gpu host, swiftshader_indirect, angle_indirect)
// Otherwise loads texture from getFrameBuffer function. (-gpu guest)
bool captureScreenshot(emugl::Renderer* renderer,
                       std::function<void(int* w, int* h, int* lineSize,
                            int* bytesPerPixel, uint8_t** frameBufferData)>
                            getFrameBuffer,
                       SkinRotation rotation,
                       android::base::StringView outputDirectoryPath,
                       std::string* outputFilepath = NULL);

}  // namespace emulation
}  // namespace android
