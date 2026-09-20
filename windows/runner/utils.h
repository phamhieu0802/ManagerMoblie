#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

// Reads the saved window bounds (x, y, width, height in logical pixels) from
// `%APPDATA%\Manager Shop Repair\window_bounds.txt`. This file is written by
// Dart (WindowStateService) whenever the window is resized/moved. Returns true
// and fills the out params only when the file exists and all 4 values are sane.
bool LoadWindowBounds(double* x, double* y, double* width, double* height);

#endif  // RUNNER_UTILS_H_
