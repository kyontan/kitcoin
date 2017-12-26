require "sinatra/base"
require "oj"

Oj.default_options = { mode: :compat, nan: :huge }

module Sinatra
  module JSONHelpers
    def json(object, options = {})
      content_type :json, charset: "utf-8"
      Oj.dump(object)
    end
  end

  helpers JSONHelpers
end
