/**
 * @jest-environment node
 */

const axios = require("axios");
const appUrl = process.env.APP_URL;

describe('Acceptance test', () => {
    it('Check application URL', async () => {
        const result = await axios.get(appUrl, {});
        expect(result.status).toEqual(200);
    });
 });