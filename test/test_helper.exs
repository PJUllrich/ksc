# Load test support files (custom process implementations, etc.)
for file <- Path.wildcard("test/support/*.ex") do
  Code.compile_file(file)
end

ExUnit.start()
