import {
  ScmIntegrationsApi,
  scmIntegrationsApiRef,
  ScmAuth,
} from '@backstage/integration-react';
import {
  AnyApiFactory, ApiRef, BackstageIdentityApi,
  configApiRef,
  createApiFactory, createApiRef, discoveryApiRef, oauthRequestApiRef, OpenIdConnectApi, ProfileInfoApi, SessionApi,
} from '@backstage/core-plugin-api';
import {OAuth2} from "@backstage/core-app-api";

// Generic SSO auth API ref — provider ID is read from config at runtime
export const ssoAuthApiRef: ApiRef<
  OpenIdConnectApi & ProfileInfoApi & BackstageIdentityApi & SessionApi
> = createApiRef({
  id: 'auth.oidc',
});

export const apis: AnyApiFactory[] = [
  createApiFactory({
    api: scmIntegrationsApiRef,
    deps: {configApi: configApiRef},
    factory: ({configApi}) => ScmIntegrationsApi.fromConfig(configApi),
  }),
  ScmAuth.createDefaultApiFactory(),
  createApiFactory({
    api: ssoAuthApiRef,
    deps: {
      discoveryApi: discoveryApiRef,
      oauthRequestApi: oauthRequestApiRef,
      configApi: configApiRef,
    },
    factory: ({ discoveryApi, oauthRequestApi, configApi }) => {
      // Read provider config from app-config.yaml
      const providerId = configApi.getOptionalString('auth.sso.providerId') ?? 'oidc';
      const providerTitle = configApi.getOptionalString('auth.sso.providerTitle') ?? 'SSO';

      return OAuth2.create({
        discoveryApi,
        oauthRequestApi,
        provider: {
          id: providerId,
          title: providerTitle,
          icon: () => null,
        },
        environment: configApi.getOptionalString('auth.environment'),
        defaultScopes: ['openid', 'profile', 'email', 'groups'],
      });
    },
  }),
];
