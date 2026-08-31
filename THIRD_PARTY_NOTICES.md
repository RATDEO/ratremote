# Third-party notices

## Thinking Orbs

The native `ThinkingOrb` animations are adapted from the visual states and
animation techniques in [thinking-orbs](https://github.com/Jakubantalik/thinking-orbs).

MIT License

Copyright (c) 2026 Jakub Antalik

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## llama.cpp

Release builds may bundle `llama-server` from [llama.cpp](https://github.com/ggml-org/llama.cpp), licensed under the MIT License. The release packager is responsible for including the license shipped with the exact bundled llama.cpp revision.

## swift-opus and Opus

RatRemote compiles the Opus decoder into the app through [swift-opus](https://github.com/alta/swift-opus). The Swift package wrapper is licensed under the BSD 3-Clause License:

Copyright (c) 2021, Alta Software. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the source and binary distributions retain the copyright notice, conditions, and disclaimer; neither the copyright holder nor contributors may be used to endorse derived products without written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS “AS IS” AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DAMAGES ARISING FROM USE OF THIS SOFTWARE.

The bundled Opus codec source is Copyright 2001-2011 Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, and contributors, and is distributed under its three-clause BSD-style license. The complete upstream license texts remain included in the resolved package source.

## Gemma 4 E2B

RatRemote can download the `ggml-org/gemma-4-E2B-it-GGUF` Q4_0 conversion from Hugging Face. The model repository identifies the artifact as Apache-2.0 licensed. Model files are downloaded only at the user's request and are not part of this source repository or default app bundle.
