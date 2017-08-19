test_check_deps() {
  ! ldd "$(which mercury)" | grep -q libmercury
}
