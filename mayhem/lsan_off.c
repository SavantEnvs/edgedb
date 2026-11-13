/* Leak detection off for every fuzz binary; ASan and its other checks stay on. */
int __lsan_is_turned_off(void) { return 1; }
