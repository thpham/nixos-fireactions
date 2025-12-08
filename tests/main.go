package main

import (
	"fmt"
	"runtime"
)

func main() {
	fmt.Printf("Hello from fireactions runner!\n")
	fmt.Printf("Go version: %s\n", runtime.Version())
	fmt.Printf("OS/Arch: %s/%s\n", runtime.GOOS, runtime.GOARCH)
}
