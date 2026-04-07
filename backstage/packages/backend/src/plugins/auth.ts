import {
  DEFAULT_NAMESPACE,
  stringifyEntityRef,
} from '@backstage/catalog-model';
import { JsonArray } from '@backstage/types';
import { createBackendModule } from '@backstage/backend-plugin-api';
import {
  authProvidersExtensionPoint,
  createOAuthProviderFactory,
  OAuthAuthenticatorResult,
} from '@backstage/plugin-auth-node';
import {
  oidcAuthenticator,
  OidcAuthResult,
} from '@backstage/plugin-auth-backend-module-oidc-provider';

// Generic OIDC auth provider — works with any OIDC-compliant IdP (Okta, Keycloak, Auth0, etc.)
// The providerId 'oidc' matches the frontend's ssoAuthApiRef and the app-config auth.providers.oidc section
export const authModuleOIDCProvider = createBackendModule({
  pluginId: 'auth',
  moduleId: 'custom-oidc',
  register(reg) {
    reg.registerInit({
      deps: {
        providers: authProvidersExtensionPoint,
      },
      async init({ providers }) {
        providers.registerProvider({
          providerId: 'oidc',
          factory: createOAuthProviderFactory({
            authenticator: oidcAuthenticator,
            profileTransform: async (
              input: OAuthAuthenticatorResult<OidcAuthResult>,
            ) => ({
              profile: {
                email: input.fullProfile.userinfo.email,
                picture: input.fullProfile.userinfo.picture,
                displayName: input.fullProfile.userinfo.name,
              },
            }),
            async signInResolver(info, ctx) {
              const { profile } = info;
              if (!profile.displayName) {
                throw new Error(
                  'Login failed, user profile does not contain a valid name',
                );
              }
              const userRef = stringifyEntityRef({
                kind: 'User',
                name: info.profile.displayName!,
                namespace: DEFAULT_NAMESPACE,
              });

              return ctx.issueToken({
                claims: {
                  sub: userRef,
                  ent: [userRef],
                  groups:
                    (info.result.fullProfile.userinfo.groups as JsonArray) ||
                    [],
                },
              });
            },
          }),
        });
      },
    });
  },
});
