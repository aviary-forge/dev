export interface Env {
    DATA: R2Bucket;
}

function notFound(): Response {
    return new Response("Not Found", {
        status: 404,
        statusText: "Not Found",
    });
}

const PERMITTED_DOMAINS = new Map([
    // Development only
    // ["shortlink.denbeigh.workers.dev", true],
    ["denb.ee", true],
]);

const REDIRECTS = new Map([
    ["", "https://www.denbeighstevens.com"],
    ["/resume", "https://www.denbeighstevens.com/resume.pdf"],
    ["/wikirace", "https://wikirace.denb.ee"],
    ["/github", "https://github.com/denbeigh2000"],
    ["/linkedin", "https://linkedin.com/in/denbeigh-stevens"],
]);

const PAGES = new Map([
    ["/pgp", respondPgp],
]);

const TRAILING_SLASH_REGEX = /\/+$/;

async function respondPgp(env: Env): Promise<Response> {
    const resp = await env.DATA.get("public-key.txt");
    if (resp === null) {
        return notFound();
    }

    const data = await resp.text()

    return new Response(data, {
        headers: {
            'Content-Type': 'text/plain',
        }
    });
}

export default {
    async fetch(
        request: Request,
        env: Env,
        _ctx: ExecutionContext
    ): Promise<Response> {
        const url = new URL(request.url);

        // Reject unwanted domains
        if (!PERMITTED_DOMAINS.has(url.hostname)) {
            return new Response("Forbidden", {
                status: 403,
                statusText: "Forbidden",
            });
        }

        const key = url.pathname.replace(TRAILING_SLASH_REGEX, '');
        const page = PAGES.get(key);
        if (page) {
            return await page(env);
        }

        const destination = REDIRECTS.get(key);
        if (!destination) {
            return notFound();
        }

        return Response.redirect(destination, 302);
    },
};
