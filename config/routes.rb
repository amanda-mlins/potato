Rails.application.routes.draw do
  resources :projects do
    resources :issues, shallow: true
  end
end
