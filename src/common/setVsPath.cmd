:: Copyright (c) Microsoft. All rights reserved.
:: Licensed under the MIT license. See LICENSE file in the project root for full license information.

@echo off

:: Find installed path of Visual Studio 2017
set _currentPath=%~dp0
call "%_currentPath%setVs2017Path.cmd"
if ErrorLevel 1 (
    exit /b 1
)

:: Set VS150COMNTOOLS
if exist "%vs2017path%\Common7\Tools\" (
    set VS150COMNTOOLS="%vs2017path%\Common7\Tools\"
)

:: Set vspath
if defined VS150COMNTOOLS (
    set vspath=%VS150COMNTOOLS%
    goto end
) else (
    echo Error: Please install visual studio 2017.
    exit /b 1
)

:end
exit /b 0
