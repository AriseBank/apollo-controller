test_devapollo() {
  ensure_import_testimage

  # shellcheck disable=SC2164
  cd "${TEST_DIR}"
  go build -tags netgo -a -installsuffix devapollo ../deps/devapollo-client.go
  # shellcheck disable=SC2164
  cd -

  mercury launch testimage devapollo

  mercury file push "${TEST_DIR}/devapollo-client" devapollo/bin/

  mercury exec devapollo chmod +x /bin/devapollo-client

  mercury config set devapollo user.foo bar
  mercury exec devapollo devapollo-client user.foo | grep bar

  mercury delete devapollo --force
}
